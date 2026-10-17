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

    # Icons (ICONS names) for a session's client: its logo in Claude Sessions,
    # and a simpler mark in Live Activity.
    CLIENT_ICONS = { "cloud" => "cloud", "cli" => "monitor", "claude-vscode" => "vscode", "claude-desktop" => "app-window",
                     "sdk-cli" => "code-xml", "sdk-ts" => "code-xml", "sdk-py" => "code-xml" }.freeze
    ENTRY_GLYPHS = { "cloud" => "cloud", "cli" => "chevron-right", "claude-vscode" => "diamond", "claude-desktop" => "app-window",
                     "sdk-cli" => "code-xml", "sdk-ts" => "code-xml", "sdk-py" => "code-xml" }.freeze

    # Stable colour per project, so a repo keeps its colour across panels.
    def project_color(name)
      theme.series[name.to_s.sum % theme.series.size]
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
      ENTRY_GLYPHS[s["entrypoint"]] || "bot"
    end

    def client_icon(s)
      CLIENT_ICONS[s["entrypoint"]] || "bot"
    end

    def status_label(s)
      s["attention"] ? "Needs you" : s["status"].to_s.capitalize
    end

    def empty_state(text, y = 14)
      txt(text, 18, y, size: 11, color: theme.muted)
    end

    # ---- Sessions ------------------------------------------------------

    def draw_sessions_body(w, h)
      list = @store.all_sessions
      if list.empty?
        return empty_state(@store.machines.empty? ? "Reading Claude Code sessions…" : "No Claude Code sessions in the last 12 hours.")
      end
      row_h = 56
      sel = @store.selected_session
      list.first((h - 6) / row_h).each_with_index { |s, i| session_row(s, 8 + i * row_h, w, row_h, sel) }
    end

    def session_row(s, y, w, row_h, sel)
      ended = s["status"] == "ended"
      mid = (w * 0.55).round
      card(10, y, w - 20, row_h - 7, selected: sel && s["id"] == sel["id"])
      avatar(18, y + 6, project_color(project_of(s)), client_icon(s), 37, dim: ended)
      txt(fit_text(Store.display_name(s), mid - 76, 12.5, :semibold), 66, y + 7, size: 12.5, color: ended ? theme.muted : theme.text, weight: :semibold)
      sub = [project_of(s), entry_name(s), (s["name"] unless ended || s["name"] == Store.display_name(s))]
      txt(fit_text(sub.compact.join(" · "), mid - 76, 10.5), 66, y + 26, size: 10.5, color: ended ? theme.dim : theme.subtle)
      status_pill(mid, y + 8, status_label(s))
      txt(Store.model_name(s["model"]), mid + 13, y + 26, size: 10.5, color: ended ? theme.dim : theme.muted)
      txt("#{s['tool_calls'].to_i} tools", w - 138, y + 7, size: 11.5, color: ended ? theme.muted : theme.text, weight: :medium, width: 100, align: :right)
      # When you last prompted it, which is what the list is sorted by.
      txt(Store.ago(Store.worked_at(s)), w - 138, y + 26, size: 10.5, color: theme.muted, width: 100, align: :right)
      chevron(w - 25, y + (row_h - 7) / 2.0)
      @c.hit(10, y, w - 20, row_h - 7) { select_session(s["id"]) }
      # Cloud sessions link to their page at claude.ai (drawn after the row's
      # own click area so it takes the click).
      if s["url"]
        link("↗", w - 160, y + 6, size: 12, color: theme.cyan) { open_session_url(s["url"]) }
      end
    end

    # ---- Live activity -------------------------------------------------

    ACTIVITY_TABS = [[:all, "All"], [:busy, "Busy"], [:idle, "Idle"]].freeze

    def draw_live_body(w, h)
      tx = 16
      ACTIVITY_TABS.each do |key, text|
        tw = tab(tx, 10, text, @store.activity_tab == key, width: 54) { set_activity_tab(key) }
        tx += tw + 8
      end

      row_h = 58
      top = 44
      items = @store.visible_sessions
      return empty_state("Nothing here right now.", top + 12) if items.empty?
      rows = [(h - top) / row_h, items.size].min
      tool_x = (w * 0.47).round
      items.first(rows).each_with_index do |s, i|
        y = top + i * row_h
        ch = row_h - 8
        color = project_color(project_of(s))
        card(10, y, w - 20, ch, accent: (color if s["status"] == "busy"))
        avatar(20, y + 7, color, entry_glyph(s), 36)
        txt(fit_text(Store.display_name(s), tool_x - 84, 12.5, :semibold), 68, y + 8, size: 12.5, color: theme.text, weight: :semibold)
        sub = [project_of(s), entry_name(s), (s["name"] unless s["name"] == Store.display_name(s))]
        txt(fit_text(s["attention"] || sub.compact.join(" · "), tool_x - 84, 10.5), 68, y + 27, size: 10.5,
            color: s["attention"] ? theme.yellow : theme.subtle)
        if (t = s["last_tool"])
          txt(fit_text(t["name"].to_s, w - 200 - tool_x, 11.5, :semibold), tool_x, y + 8, size: 11.5, color: theme.cyan, weight: :semibold)
          txt(fit_text(t["detail"], w - 200 - tool_x, 10, font: :mono), tool_x, y + 27, size: 10, color: theme.muted, mono: true)
        end
        txt(Store.ago(s["last_at"] || s["status_at"]), w - 190, y + 17, size: 10.5, color: theme.text, width: 70, align: :right)
        status_pill(w - 108, y + 17, status_label(s))
        chevron(w - 25, y + ch / 2.0)
        @c.hit(10, y, w - 20, ch) { select_session(s["id"]) }
        @c.hit(tool_x, y, w - 200 - tool_x, ch) { open_overlay(last_tool_overlay(s)) } if s["last_tool"]
      end
    end

    # ---- Projects ------------------------------------------------------

    def draw_projects_body(w, h)
      list = @store.projects
      return empty_state("No Claude Code activity in the last 24 hours.") if list.empty?
      card_h = 62
      rows = [(h - 8) / (card_h + 8), list.size].min
      max_tok = [list.map { |p| p["out_tokens"].to_i }.max, 1].max
      list.first(rows).each_with_index do |p, i|
        y = 8 + i * (card_h + 8)
        name = File.basename(p["cwd"].to_s)
        color = project_color(name)
        card(10, y, w - 20, card_h, accent: color)
        # The project's colour bar, inside the card and inset from its edges.
        @c.glow(16, y + 9, 4, card_h - 18, curve: 2, blur: 5, color: col(color, 0.25))
        grad_rect(16, y + 9, 4, card_h - 18, col(tint(color, 0.2)), col(shade(color, 0.2)), curve: 2)
        square_icon(30, y + 12, color, name[0].to_s.upcase, 38)
        right_w = 150
        txt(fit_text(name, w - 110 - right_w, 13, :semibold), 80, y + 12, size: 13, color: theme.text, weight: :semibold)
        txt(fit_text([p["branch"], p["host"]].compact.join(" · "), w - 110 - right_w, 10.5), 80, y + 33, size: 10.5, color: theme.subtle)
        txt("#{Store.count(p['out_tokens'])} tok", w - 40 - right_w, y + 12, size: 12, color: theme.text, weight: :semibold, width: right_w, align: :right)
        txt("#{p['prompts'].to_i} prompts · #{Store.ago(p['last_at'])}", w - 40 - right_w, y + 33, size: 10, color: theme.muted, width: right_w, align: :right)
        hbar(w - 40 - 96, y + card_h - 9, 96, 3, p["out_tokens"].to_i * 100.0 / max_tok, color, no_glow: true)
        chevron(w - 24, y + card_h / 2.0)
        @c.hit(10, y, w - 20, card_h) { open_overlay(project_overlay(p)) }
      end
    end

    # ---- Tool calls ----------------------------------------------------

    TOOL_TABS = [[:all, "All"], [:edits, "Edits"], [:shell, "Shell"], [:errors, "Errors"]].freeze

    # The theme's `tools` table: by name, "mcp" for MCP tools, else its default.
    def tool_color(name)
      theme.tool_color(name)
    end

    def draw_tools_body(w, h)
      tx = 16
      counts = @store.tool_counts
      session_only_toggle(w)
      TOOL_TABS.each do |key, text|
        tw = tab(tx, 10, "#{text} (#{Store.count(counts[key])})", @store.tool_filter == key) { set_tool_filter(key) }
        tx += tw + 8
      end
      k = [w / 466.0, 1].max
      cx = [22, 70, 168, 262].map { |x| (x * k).round }
      @c.rect(10, 44, w - 20, 26, curve: 7, fill: col(theme.card_top, 0.9))
      %w[TIME SESSION TOOL DETAIL].each_with_index { |name, i| txt(name, cx[i], 51, size: 9.5, color: tint(theme.cyan, 0.35), weight: :semibold, kerning: 0.5) }

      row_h = 25
      top = 74
      items = @store.visible_tools
      return empty_state("No tool calls in the last 24 hours.", top + 8) if items.empty?
      rows = [(h - top) / row_h, items.size].min
      items.first(rows).each_with_index do |e, i|
        y = top + i * row_h
        fade_line(12, w - 12, y + row_h - 0.5, theme.border, alpha: 0.35, peak: 0.4)
        err = e["kind"] == "error"
        name = err ? "error" : e["title"].to_s
        txt(Time.at(e["at"]).strftime("%H:%M"), cx[0], y + 6, size: 10.5, color: theme.text)
        txt(fit_text(e["session"], cx[2] - cx[1] - 10, 10.5), cx[1], y + 6, size: 10.5, color: theme.text)
        glow_dot(cx[2], y + 9, col(err ? theme.red : tool_color(name)), 7)
        txt(fit_text(name, cx[3] - cx[2] - 22, 10.5), cx[2] + 13, y + 6, size: 10.5, color: err ? theme.red : theme.text)
        txt(fit_text(e["detail"], w - cx[3] - 40, 10, font: :mono), cx[3], y + 6.5, size: 10, color: err ? theme.red : theme.muted, mono: true)
        chevron(w - 22, y + row_h / 2.0, col(theme.muted, 0.7), 11)
        @c.hit(10, y, w - 20, row_h) { open_overlay(event_overlay(e)) }
      end
    end

    # ---- Usage ---------------------------------------------------------

    RANGE_STEP = { "12h" => 1, "24h" => 1, "7d" => 6, "30d" => 24 }.freeze
    RANGE_LABEL = { "12h" => "Last 12 hours", "24h" => "Last 24 hours", "7d" => "Last 7 days", "30d" => "Last 30 days" }.freeze
    # [legend key, index in an hourly row]; the theme's `usage` table colours them.
    SERIES = [["Tool calls", 2], ["Output k-tok", 1], ["Prompts", 3], ["Errors", 4]].freeze

    def draw_usage_body(w, h)
      t = @store.totals
      tiles = [["Prompts", t[:prompts], "message-square", :prompts], ["Tool calls", t[:tool_calls], "settings", :tools],
               ["Output tokens", t[:out_tokens], "layers", :tokens], ["Tool errors", t[:errors], "circle-alert", :tools]]
      gap = 12
      bw = ((w - 32 - gap * 3) / 4.0).floor
      # Narrow tiles (the window at its design size) put a smaller icon
      # beside the label instead of a tile beside both lines.
      compact = bw < 150
      tiles.each_with_index do |(name, value, glyph, view), i|
        x = 16 + i * (bw + gap)
        c = name == "Tool errors" && value.positive? ? theme.red : (name == "Tool errors" ? theme.slate : theme.cyan)
        @c.glow(x, 8, bw, 56, curve: 10, blur: 10, color: col(c, 0.10))
        grad_rect(x, 8, bw, 56, col(theme.card_top, 0.9), col(theme.panel2, 0.9), curve: 10)
        @c.rect(x, 8, bw, 56, curve: 10, stroke: col(c, 0.6))
        fade_line(x + 10, x + bw - 10, 8.5, c, alpha: 0.6, peak: 0.3)
        if compact
          icon(glyph, x + 19, 23, 15, col(tint(c, 0.1)))
          txt(fit_text(name, bw - 40, 10, :semibold), x + 32, 16.5, size: 10, color: tint(c, 0.1), weight: :semibold)
          txt(Store.count(value), x + 12, 35, size: 18, color: theme.white, weight: :bold)
        else
          square_icon(x + 11, 19, c == theme.cyan ? theme.tile_cyan : c, glyph, 34)
          txt(fit_text(name, bw - 62, 11, :semibold), x + 54, 17, size: 11, color: tint(c, 0.1), weight: :semibold)
          txt(Store.count(value), x + 54, 34, size: 18, color: theme.white, weight: :bold)
        end
        @c.hit(x, 8, bw, 56) { open_overlay(view_overlay(view)) }
      end

      range = @store.chart_range
      step = RANGE_STEP[range]
      buckets = @store.hourly(Store::CHART_RANGES[range]).each_slice(step).map do |slice|
        [slice.first[0], *(1..4).map { |i| slice.sum { |r| r[i] } }]
      end
      unit = { 1 => "h", 6 => "6h", 24 => "day" }[step]
      format = { 1 => "%H:00", 6 => "%a %H:00", 24 => "%b %-d" }[step]
      series = SERIES.map do |key, idx|
        color = theme.usage_color(key)
        values = buckets.map { |b| idx == 1 ? (b[1] / 1000.0).round(1) : b[idx] }
        { key: key, name: "#{key} / #{unit}", color: color, values: values }
      end
      visible = series.reject { |sr| @store.hidden_series.include?(sr[:key]) }
      max = nice_ceiling(visible.flat_map { |sr| sr[:values] }.max.to_f)
      chart_w = w - 130
      every = [(buckets.size / 7.0).ceil, 1].max
      last = buckets.size - 1
      # Every `every`th label, plus the last one if it isn't crowding its
      # neighbour.
      shown = (0..last).step(every).to_a
      shown << last if last - shown.last >= every
      labels = buckets.each_with_index.map { |b, i| shown.include?(i) ? Time.at(b[0]).strftime(format) : "" }
      line_chart(14, 80, chart_w, h - 88, labels, visible, max: max, steps: chart_steps(max))

      # A click on a column opens that period's breakdown.
      gx = 44
      gw = chart_w - 30
      colw = gw / [buckets.size - 1, 1].max.to_f
      buckets.each_with_index do |b, i|
        @c.hit(gx + colw * i - colw / 2, 80, colw, h - 88 - 20) { open_overlay(period_overlay(b[0], step)) }
      end

      rx = chart_w + 26
      txt(fit_text("#{RANGE_LABEL[range]}, all", 104, 10.5), rx, 76, size: 10.5, color: theme.muted)
      Store::CHART_RANGES.keys.each_with_index do |key, i|
        tab(rx + (i % 2) * 52, 94 + (i / 2) * 27, key, key == range, width: 46, height: 22) { set_chart_range(key) }
      end
      series.each_with_index do |sr, i|
        y = 152 + i * 20
        hidden = @store.hidden_series.include?(sr[:key])
        hidden ? dot(rx + 1, y + 4, col(sr[:color], 0.25), 7) : glow_dot(rx + 1, y + 4, col(sr[:color]), 7)
        txt(fit_text(sr[:name], w - rx - 30, 10.5), rx + 16, y - 0.5, size: 10.5, color: hidden ? theme.dim : theme.text)
        @c.hit(rx - 4, y - 4, 112, 21) { toggle_series(sr[:key]) }
      end
    end

    # Gridlines for a chart topping out at `max`: 4 to 6 of them, each a round
    # number (1, 2, 2.5 or 5 times a power of ten).
    def chart_steps(max)
      round = ->(v) { m = v / 10**Math.log10(v).floor; [1, 2, 2.5, 5, 10].any? { |n| (m - n).abs < 1e-9 } }
      [5, 6, 4].find { |n| round.(max.to_f / n) } || 5
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

    # Four ring gauges over a strip of three figures, after the designer's
    # reference: rings separated by faint dividers with a spark at the top,
    # and one card for uptime, load average and the report's age.
    def draw_health_body(w, h)
      m = health_machine
      return empty_state("Waiting for the first probe…") unless m
      hl = m["health"]
      load_pct = hl["load"] && hl["cpus"].to_i.positive? ? hl["load"] * 100.0 / hl["cpus"] : 0
      host_sessions = @store.sessions.select { |s| s["host"] == m["host"] }
      busy_pct = host_sessions.empty? ? 0 : host_sessions.count { |s| s["status"] == "busy" } * 100.0 / host_sessions.size
      aqua = mix(theme.cyan, theme.green, 0.45)
      gauges = [[load_pct, "Load", theme.cyan, "activity"], [hl["mem_pct"], "Memory", aqua, "cpu"],
                [hl["disk_pct"], "Disk", theme.cyan, "database"], [busy_pct, "Busy", theme.health_busy, "activity"]]
      strip_h = [[(h * 0.3).round, 58].max, 72].min
      strip_y = h - strip_h - 12
      ring_area = strip_y - 8
      slot_w = w / gauges.size.to_f
      r = [(ring_area - 36) / 2.0, slot_w * 0.39, 46].min.floor
      cy = ring_area / 2.0 - 5
      gauges.each_with_index do |(pct, name, color, glyph), i|
        donut(slot_w * i + slot_w / 2, cy, r, pct.to_f, pct.to_f > 90 ? theme.red : color, label: name, icon: glyph)
        next if i.zero?
        x = (slot_w * i).round
        fade_vline(x, 8, ring_area - 4, theme.border, alpha: 0.5, peak: 0.3)
        glow_dot(x - 2.5, 2, col(theme.cyan, 0.9), 5)
      end
      metrics = [
        ["history",     "Uptime",      hl["uptime_s"] ? uptime_text(hl["uptime_s"]) : "—"],
        ["activity",    "Load avg",    hl["load"] ? format("%.2f / %d", hl["load"], hl["cpus"].to_i) : "—"],
        ["alarm-clock", "Last report", Store.ago(m["seen_at"])]
      ]
      bx = 14
      bw = w - 28
      @c.glow(bx, strip_y, bw, strip_h, curve: 10, blur: 12, color: col(theme.bolt, 0.14))
      box(bx, strip_y, bw, strip_h, curve: 10, stroke: col(theme.border, 0.55))
      fade_line(bx + 10, bx + bw - 10, strip_y + 0.5, theme.cyan, alpha: 0.7, peak: 0.3)
      cw = bw / 3.0
      icon_d = [strip_h * 0.4, 30].min
      metrics.each_with_index do |(glyph, name, value), i|
        x = bx + cw * i
        fade_vline(x.round, strip_y + 10, strip_y + strip_h - 10, theme.border, alpha: 0.5) if i.positive?
        icon(glyph, x + 22, strip_y + strip_h / 2.0, icon_d, col(theme.cyan), width: 1.6)
        tx = x + 40
        tw = cw - 46
        ty = strip_y + strip_h / 2.0 - 20
        txt(fit_text(name.upcase, tw, 9.5, :semibold), tx, ty, size: 9.5, color: mix(theme.cyan, theme.text, 0.35), weight: :semibold, kerning: 1)
        txt(fit_text(value, tw, 17, :semibold), tx, ty + 16, size: 17, color: theme.text, weight: :semibold)
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
      row_h = 31
      rows = [(h - 8) / row_h, list.size].min
      name_w = [(w * 0.28).round, 140].min
      list.first(rows).each_with_index do |e, i|
        y = 6 + i * row_h
        avatar(16, y + 3, project_color(e["project"]), "chevron-right", 24)
        txt(fit_text(e["session"], name_w, 11.5, :semibold), 50, y + 7, size: 11.5, color: theme.text, weight: :semibold)
        txt(fit_text(e["detail"], w - name_w - 150, 11), 60 + name_w, y + 7.5, size: 11, color: theme.text_detail)
        txt(Store.ago(e["at"]), w - 82, y + 7.5, size: 10.5, color: theme.muted, width: 66, align: :right)
        fade_line(50, w - 14, y + row_h - 1, theme.border, alpha: 0.25, peak: 0.3) if i < rows - 1
        @c.hit(4, y, w - 8, row_h) { open_overlay(event_overlay(e)) }
      end
    end

    # ---- Session details -----------------------------------------------

    def draw_detail_body(w, h)
      s = @store.selected_session
      return empty_state("Select a session to see its details.") unless s
      color = project_color(project_of(s))
      avatar(18, 10, color, entry_glyph(s), 44)
      txt(fit_text(Store.display_name(s), w - 170, 13, :semibold), 74, 9, size: 13, color: theme.text, weight: :semibold)
      status_pill(74, 29, status_label(s))
      link("Open in claude.ai ↗", 150, 29, size: 10.5, color: theme.cyan) { open_session_url(s["url"]) } if s["url"]
      link("Timeline ›", w - 84, 11, size: 10.5, color: theme.cyan, weight: :medium) { open_overlay(timeline_overlay(s)) }
      txt(fit_text([s["host"], entry_name(s), s["version"] && "v#{s['version']}"].compact.join(" · "), w - 100, 10.5),
          74, 46, size: 10.5, color: theme.subtle)

      col_w = ((w - 32) * 0.52).to_i
      bh = [h - 76, 104].min
      box(12, 68, col_w, bh, curve: 9, stroke: col(theme.border, 0.45))
      label("Last prompt", 22, 76, size: 10, color: theme.muted)
      txt(fit_text(s["last_prompt"] || "—", col_w - 20, 10.5), 22, 90, size: 10.5, color: theme.text)
      t = s["last_tool"]
      txt(fit_text(t ? "#{t['name']}: #{t['detail']}" : "No tool calls yet", col_w - 20, 10, font: :mono), 22, 106, size: 10,
          color: theme.cyan, mono: true)
      rows = [[s["status"] == "ended" ? "Last active" : "Started", Store.ago(s["status"] == "ended" ? s["last_at"] : s["started_at"])],
              ["Model", Store.model_name(s["model"])]]
      rows.each_with_index do |(k, v), i|
        label(k, 22, 126 + i * 17, size: 10, color: theme.muted)
        txt(v, 92, 126 + i * 17, size: 10.5, color: theme.text)
      end

      cx = 26 + col_w
      tok = s["tokens"] || {}
      rows = [
        ["Branch",      s["branch"] || "—"],
        ["Context",     context_text(s)],
        ["Output",      "#{Store.count(tok['out'])} tok"],
        ["Cache read",  "#{Store.count(tok['cache_read'])} tok"],
        ["Tools",       "#{s['tool_calls'].to_i} (#{s['errors'].to_i} err)"],
        ["Prompts",     s["prompts"].to_i.to_s]
      ]
      rows.each_with_index do |(k, v), i|
        label(k, cx, 72 + i * 17.5, size: 10, color: theme.muted)
        color = if k == "Context" then context_color(s)
                elsif k == "Tools" && s["errors"].to_i.positive? then theme.yellow
                else theme.text
                end
        txt(fit_text(v, w - cx - 84, 10.5), cx + 70, 72 + i * 17.5, size: 10.5, color: color)
      end
    end

    # ---- Event log -----------------------------------------------------


    def draw_log_body(w, h)
      session_only_toggle(w)
      list = @store.visible_events
      return empty_state("No events in the last 24 hours.") if list.empty?
      row_h = 21
      rows = [(h - 10) / row_h, list.size].min
      kind_x = 58
      text_x = (w * 0.38).round.clamp(150, 230)
      list.first(rows).each_with_index do |e, i|
        y = 7 + i * row_h
        txt(Time.at(e["at"]).strftime("%H:%M"), 16, y, size: 10.5, color: theme.muted)
        kind = %w[tool lifecycle].include?(e["kind"]) ? e["title"].to_s : e["kind"].to_s
        txt(fit_text(kind, text_x - kind_x - 8, 10.5, :medium), kind_x, y, size: 10.5, color: theme.kind_color(e["kind"]), weight: :medium)
        txt(fit_text("#{e['session']}: #{e['detail']}", w - text_x - 14, 10.5), text_x, y, size: 10.5, color: theme.text_detail)
        @c.hit(10, y - 3, w - 20, row_h) { open_overlay(event_overlay(e)) }
      end
    end

    # ---- Machines ------------------------------------------------------

    def draw_machines_body(w, h)
      list = @store.machines
      return empty_state("Waiting for the first probe…") if list.empty?
      row_h = 46
      rows = [(h - 8) / row_h, list.size].min
      list.first(rows).each_with_index do |m, i|
        y = 8 + i * row_h
        c = m["online"] ? theme.green : theme.red
        glyph = m["local"] ? "monitor" : (m["host"] == CloudFeed::HOST ? "cloud" : "server")
        square_icon(16, y + 2, c == theme.green ? theme.tile_green : c, glyph, 34)
        txt(fit_text(m["host"], w - 130, 11.5, :semibold), 62, y + 4, size: 11.5, color: theme.text, weight: :semibold)
        os = m["health"]["os"]
        sub = [("#{m['sessions']} sessions" if m["online"]), os, (m["online"] ? nil : "last seen #{Store.ago(m['seen_at'])}")]
        txt(fit_text(sub.compact.join(" · "), w - 80, 10), 62, y + 22, size: 10, color: theme.muted)
        txt(m["online"] ? "online" : "offline", w - 74, y + 5, size: 10.5, color: c, weight: :medium, width: 60, align: :right)
        @c.hit(4, y, w - 8, row_h) { open_overlay(machine_overlay(m)) }
      end
    end

    # "This session only", in the panel's title bar: narrows Tool Calls and
    # the Event Log to the session selected in Claude Sessions.
    def session_only_toggle(w)
      on = @store.session_only
      text = "this session only"
      tw = text_w(text, 10.5) + 30
      x = w - (@store.page == :overview ? 40 : 18) - tw
      y = -Layout::PANEL_TITLE_H + 8
      @c.rect(x, y, tw, 22, curve: 11, fill: col(on ? theme.cyan : theme.panel2, on ? 0.12 : 0.6), stroke: col(on ? theme.cyan : theme.border, on ? 0.7 : 0.5))
      @c.circle(x + 12, y + 11, 3.5, fill: on ? col(theme.cyan) : nil, stroke: col(on ? theme.cyan : theme.muted), strokewidth: 1.2)
      txt(text, x + 21, y + 4.5, size: 10.5, color: on ? theme.cyan : theme.muted)
      @c.hit(x, y, tw, 22) { toggle_session_only }
    end

    # ---- context meter -------------------------------------------------

    # "52k / 1M · 5%": the session's context against its model's window.
    def context_text(s)
      return "—" unless s["context"]
      window = Store.context_window(s["model"], s["context"])
      "#{Store.count(s['context'])} / #{Store.count(window)} · #{(s['context'] * 100.0 / window).round}%"
    end

    def context_color(s)
      return theme.text unless s["context"]
      pct = s["context"].to_f / Store.context_window(s["model"], s["context"])
      pct >= 0.95 ? theme.red : (pct >= 0.8 ? theme.yellow : theme.text)
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

    TOKEN_RANGES = { "24h" => 24, "7d" => 168, "30d" => 720 }.freeze

    def tokens_overlay(range = "24h")
      tb = @store.token_breakdown(TOKEN_RANGES.fetch(range))
      t = tb[:totals]
      o = Overlay.new("Tokens", subtitle: "#{RANGE_LABEL[range] || "Last #{range}"}, every machine and claude.ai")
      o.tabs!(TOKEN_RANGES.keys, range) { |r| tokens_overlay(r) }
      o.field("Output", Store.count(t["out"]))
      o.field("Input", Store.count(t["in"]))
      o.field("Cache read", Store.count(t["cache_read"]))
      o.field("Cache write", Store.count(t["cache_write"]))
      o.field("Total input", "#{Store.count(t['in'] + t['cache_read'] + t['cache_write'])}  (input + cache read + cache write: everything sent to the model)")
      o.field("Cache hit", tb[:cache_hit] && "#{(tb[:cache_hit] * 100).round(1)}% of prompt tokens were read from cache")
      kinds = ->(x) { [Store.count(x["out"]), Store.count(x["in"]), Store.count(x["cache_read"]), Store.count(x["cache_write"])] }
      head = %w[output input cache\ read cache\ write]
      o.block("By client", table(["client", *head], tb[:by_client].sort_by { |_, x| -x["out"] }.map { |c, x| [c, *kinds.(x)] }))
      o.block("By model", table(["model", *head], tb[:by_model].sort_by { |_, x| -x["out"] }.map { |m, x| [Store.model_name(m), *kinds.(x)] }))
      o.block("By project", table(["project", *head], tb[:by_project].sort_by { |_, x| -x["out"] }.map { |pr, x| [pr, *kinds.(x)] }))
      day = tb[:period] == 86_400
      o.block(day ? "By day" : "By hour", table([day ? "day" : "hour", *head],
                                                tb[:by_period].sort_by(&:first).reverse.map { |at, x| [Time.at(at).strftime(day ? "%a %b %-d" : "%a %H:00"), *kinds.(x)] }))
      o.block("By session (whole session so far, sessions from the last 12 hours)",
              table(["session", *head], tb[:by_session].first(30).map { |n, x| [n.to_s[0, 60], *kinds.(x)] }))
      o.note("claude.ai sessions report tokens once their environment runs the updated setup script (cloud/setup.sh); before that they're missing here.")
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
      @store.usage(24).each { |r| by_model[r[Store::U[:model]]] += r[Store::U[:out]] if r[Store::U[:project]] == name }
      o.block("Output by model (24h)", table(%w[model output], by_model.reject { |_, v| v.zero? }.sort_by { |_, v| -v }.map { |m, v| [Store.model_name(m), Store.count(v)] }))
      o.block("Sessions", table(%w[status session client tools last\ worked], sessions.map { |s| [status_label(s), Store.display_name(s).to_s[0, 50], entry_name(s), s["tool_calls"].to_i, Store.ago(Store.worked_at(s))] }, left: [0, 1, 2]))
      files = @store.tool_events.select { |e| e["project"] == name && EDIT_TOOLS.include?(e["title"]) }.map { |e| e["detail"].to_s }.reject(&:empty?).tally
      o.block("Files edited most (24h)", table(%w[file edits], files.sort_by { |_, n| -n }.first(20).map { |f, n| [f, n] })) unless files.empty?
      o
    end

    # One chart column: `step` hours from `start`.
    def period_overlay(start, step)
      stop = start + step * 3600
      u = Store::U
      rows = @store.usage([((Store.current_hour - start) / 3600) + 1, 1].max).select { |r| r[u[:hour]] >= start && r[u[:hour]] < stop }
      sum = ->(k) { rows.sum { |r| r[u[k]].to_i } }
      fmt = step == 24 ? "%a %b %-d" : "%a %b %-d, %H:00"
      o = Overlay.new("Usage #{Time.at(start).strftime(fmt)}#{step > 1 ? " – #{Time.at(stop).strftime(step == 24 ? '%a %b %-d' : '%H:00')}" : ''}",
                      subtitle: "Every machine")
      o.field("Prompts", sum.(:prompts))
      o.field("Tool calls", sum.(:tools))
      o.field("Errors", sum.(:errors))
      o.field("Output tokens", Store.count(sum.(:out)))
      by_project = rows.group_by { |r| r[u[:project]].empty? ? "(unknown)" : r[u[:project]] }
                       .map { |pr, rs| [pr, rs.sum { |r| r[u[:prompts]] }, rs.sum { |r| r[u[:tools]] }, Store.count(rs.sum { |r| r[u[:out]] })] }
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
        label(k, 16, y, size: 9, color: theme.muted)
        txt(clip(v, (w - 170) / 5.5), 150, y, size: 9, color: k == "Probe" && @store.probe_error ? theme.red : theme.text)
      end
      y = 10 + rows.size * 24 + 10
      txt("Window", 16, y, size: 9, color: theme.muted)
      link("[ Toggle title bar ]", 150, y) { @host.toggle_decorations }
      link("[ Toggle fullscreen ]", 300, y) { @host.toggle_fullscreen }
      link("[ Quit ]", 460, y, color: theme.red) { @host.quit }
      txt("Drag the header bar to move the window. Esc leaves fullscreen; F11 or Ctrl+Cmd+F toggles it.",
          16, y + 28, size: 9, color: theme.dim, width: w - 32)
      ny = y + 54
      txt("Alerts", 16, ny, size: 9, color: theme.muted)
      txt("Dock badge and bounce when a session waits on you: always on.", 150, ny, size: 9, color: theme.text)
      on = @store.notifications?
      link(on ? "[ macOS notifications: on ]" : "[ macOS notifications: off ]", 150, ny + 18, color: on ? theme.cyan : theme.muted) do
        @store.notifications = !on
        @host.invalidate
      end
      txt("(a script-posted notification opens Script Editor when clicked)", 330, ny + 18, size: 8, color: theme.dim)
      y += 64 + 50
      txt("Add another machine", 16, y, size: 9, color: theme.muted)
      txt("1. Here: start the dashboard with BOT_OPS_LISTEN=0.0.0.0:47800 and a BOT_OPS_TOKEN of 16+ characters.",
          150, y, size: 9, color: theme.text, width: w - 170)
      txt("2. There: BOT_OPS_COLLECTOR=http://<this machine>:47800 BOT_OPS_TOKEN=<same> bin/bot-ops-agent",
          150, y + 18, size: 9, color: theme.text, width: w - 170, mono: true)
      theme_picker(16, y + 48, w)
    end

    THEME_MENU_W = 220
    THEME_ROW_H  = 22

    # A drop-down of every theme on disk (see BotOps::Theme). Drawn last so
    # the open list paints over the rows below it.
    def theme_picker(x, y, w)
      themes = Theme.available
      bx = x + 134
      label("Theme", x, y, size: 9, color: theme.muted)
      @c.rect(bx, y - 5, THEME_MENU_W, THEME_ROW_H, curve: 6, fill: col(theme.panel2),
              stroke: col(theme.border, theme_menu? ? 0.9 : 0.5), strokewidth: 1)
      txt(theme.name, bx + 10, y, size: 9.5, color: theme.text, weight: :medium)
      icon("chevron-down", bx + THEME_MENU_W - 12, y + 6, 12, col(theme.cyan, 0.9))
      @c.hit(bx, y - 5, THEME_MENU_W, THEME_ROW_H) { toggle_theme_menu }
      where = theme.path.to_s.sub("#{File.dirname(Theme::APP_DIR)}/", "").sub(Dir.home, "~")
      txt("#{where}  ·  your own: bundle exec rake theme:custom, then edit themes/custom.yml (it reloads as you save)",
          bx + THEME_MENU_W + 12, y, size: 8, color: theme.dim, width: w - bx - THEME_MENU_W - 28)
      return unless theme_menu?

      @c.hit_everywhere { close_theme_menu }
      ly = y + THEME_ROW_H
      lh = themes.size * THEME_ROW_H + 8
      @c.glow(bx, ly, THEME_MENU_W, lh, blur: 14, color: col(theme.edge_soft, 0.5))
      @c.rect(bx, ly, THEME_MENU_W, lh, curve: 6, fill: col(theme.overlay_bg, 0.98), stroke: col(theme.border, 0.8), strokewidth: 1)
      themes.each_with_index do |(slug, name, _path), i|
        ry = ly + 4 + i * THEME_ROW_H
        current = slug == theme.slug
        @c.rect(bx + 4, ry, THEME_MENU_W - 8, THEME_ROW_H, curve: 4, fill: col(theme.card_top, 0.9)) if current
        @c.circle(bx + 14, ry + THEME_ROW_H / 2.0, 2.5, fill: col(theme.cyan)) if current
        txt(name, bx + 24, ry + 5, size: 9.5, color: current ? theme.cyan : theme.text, weight: current ? :medium : :normal)
        @c.hit(bx, ry, THEME_MENU_W, THEME_ROW_H) { choose_theme(slug) }
      end
    end
  end
end
