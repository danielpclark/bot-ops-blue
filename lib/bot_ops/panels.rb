# frozen_string_literal: true

module BotOps
  # Bodies of each dashboard panel. Every method receives the body width and
  # height so the same drawing can be reused on the full-size sub pages.
  module Panels
    include Theme

    ARROW = " → "
    CHECK = "✓"

    # Truncate text that would otherwise run into the next column.
    def clip(str, max_chars)
      s = str.to_s
      s.length > max_chars ? "#{s[0, [max_chars - 1, 1].max]}…" : s
    end

    # ---- Bot fleet -----------------------------------------------------

    def draw_fleet_body(w, h)
      row_h = 44
      rows = [(h - 4) / row_h, @store.bots.size].min
      @store.bots.first(rows).each_with_index do |bot, i|
        y = 2 + i * row_h
        hline(12, w - 12, y + row_h - 1, col(CYAN, 0.07)) if i < rows - 1
        avatar(14, y + 7, bot.color, bot.glyph, 30)
        name = txt(bot.name, 56, y + 5, size: 10, color: TEXT, weight: "bold")
        name.click { select_bot(bot.id) }
        txt(bot.role, 56, y + 21, size: 9, color: MUTED)
        status_pill(196, y + 6, bot.status)
        pct = bot.status == "Running" ? [bot.tasks * 8, 100].min : 4
        hbar(196, y + 27, 96, 4, pct, bot.status == "Running" ? bot.color : DIM, no_glow: true)
        txt("#{bot.tasks} tasks", w - 100, y + 5, size: 9, color: bot.tasks.zero? ? DIM : TEXT, width: 88, align: "right")
        txt(Store.duration(bot.uptime_s), w - 100, y + 21, size: 9, color: MUTED, width: 88, align: "right")
      end
    end

    # ---- Live activity -------------------------------------------------

    ACTIVITY_TABS = [[:live, "Live"], [:queue, "Queue"], [:completed, "Completed"], [:errors, "Errors"]].freeze

    def draw_activity_body(w, h)
      tx = 14
      ACTIVITY_TABS.each do |key, text|
        tw = tab(tx, 4, text, @store.activity_tab == key) { set_activity_tab(key) }
        tx += tw + 6
      end
      txt("‹ ›", w - 44, 6, size: 11, color: MUTED)

      row_h = 44
      top = 32
      items = @store.visible_activity
      rows = [(h - top) / row_h, items.size].min
      if items.empty?
        txt("Nothing here right now.", 16, top + 12, size: 10, color: MUTED)
        return
      end
      items.first(rows).each_with_index do |a, i|
        y = top + i * row_h
        bot = @store.bot(a.bot_id)
        box(10, y, w - 20, row_h - 6, fill: col(PANEL2), stroke: col(CYAN, 0.12), curve: 6)
        avatar(18, y + 4, bot ? bot.color : CYAN, bot ? bot.glyph : "?", 30)
        txt(bot ? bot.name : a.bot_id.to_s, 58, y + 3, size: 10, color: TEXT, weight: "bold")
        txt(a.task, 58, y + 19, size: 9, color: MUTED)
        txt(Store.ago(a.started_at), w - 292, y + 11, size: 9, color: MUTED)
        bar_color = a.status == "Failed" ? RED : (bot ? bot.color : CYAN)
        hbar(w - 234, y + 15, 88, 6, a.progress, bar_color)
        txt("#{a.progress}%", w - 140, y + 11, size: 9, color: TEXT, width: 34, align: "right")
        if a.status == "Completed"
          txt("#{CHECK} Completed", w - 92, y + 11, size: 9, color: TEAL)
        else
          status_pill(w - 90, y + 12, a.status)
        end
      end
    end

    # ---- Workflows -----------------------------------------------------

    def draw_workflows_body(w, h)
      card_h = 52
      rows = [(h - 6) / (card_h + 6), @store.workflows.size].min
      @store.workflows.first(rows).each_with_index do |wf, i|
        y = 4 + i * (card_h + 6)
        box(10, y, w - 20, card_h, fill: col(PANEL2), stroke: col(wf.color, 0.25), curve: 7)
        square_icon(18, y + 11, wf.color, wf.glyph, 30)
        txt(wf.name, 58, y + 9, size: 10, color: TEXT, weight: "bold")
        txt(wf.steps.join(ARROW), 58, y + 27, size: 9, color: MUTED)
        status_pill(w - 110, y + 12, wf.status)
        txt("#{wf.done}/#{wf.total}", w - 60, y + 28, size: 9, color: MUTED, width: 40, align: "right")
        hbar(w - 108, y + 32, 44, 3, wf.done * 100.0 / wf.total, wf.color, no_glow: true)
      end
    end

    # ---- Task queue ----------------------------------------------------

    QUEUE_TABS = [[:all, "All"], [:pending, "Pending"], [:running, "Running"], [:failed, "Failed"]].freeze
    QUEUE_COLS = [[14, "ID"], [62, "TASK"], [176, "AGENT"], [282, "PRIORITY"], [346, "STATUS"], [414, "AGE"]].freeze

    def draw_queue_body(w, h)
      tx = 14
      QUEUE_TABS.each do |key, text|
        n = @store.queue_counts[key]
        color = { all: TEAL, pending: YELLOW, running: CYAN, failed: RED }[key]
        tw = tab(tx, 4, "#{text} (#{n})", @store.queue_filter == key, color: color) { set_queue_filter(key) }
        tx += tw + 6
      end
      QUEUE_COLS.each { |x, name| label(name, x, 34, size: 8, color: DIM, weight: "bold") }
      hline(10, w - 10, 48, col(CYAN, 0.12))

      row_h = 22
      top = 52
      items = @store.visible_tasks
      rows = [(h - top) / row_h, items.size].min
      items.first(rows).each_with_index do |t, i|
        y = top + i * row_h
        hline(10, w - 10, y + row_h - 1, col(CYAN, 0.05))
        txt("##{t.id}", 14, y + 3, size: 9, color: MUTED, mono: true)
        txt(t.title, 62, y + 3, size: 9, color: TEXT)
        dot(176, y + 8, Theme.status_color("Running"), 4)
        txt(t.agent, 184, y + 3, size: 9, color: TEXT)
        priority_pill(282, y + 4, t.priority)
        status_pill(346, y + 4, t.status)
        txt(Store.ago(t.created_at).sub(" ago", ""), 414, y + 3, size: 9, color: MUTED)
      end
    end

    # ---- Pipeline ------------------------------------------------------

    def draw_pipeline_body(w, h)
      stages = @store.pipeline_stages
      bw = 100
      gap = (w - 32 - stages.size * bw) / (stages.size - 1)
      stages.each_with_index do |s, i|
        x = 16 + i * (bw + gap)
        rect(left: x, top: 6, width: bw, height: 56, curve: 8, fill: col(PANEL2), stroke: col(CYAN, 0.55), strokewidth: 1)
        rect(left: x + 2, top: 8, width: bw - 4, height: 52, curve: 7, fill: col(CYAN, 0.03), stroke: col(CYAN, 0.12))
        square_icon(x + 8, 16, CYAN, s[:glyph], 26)
        txt(s[:name], x + 42, 13, size: 10, color: CYAN, weight: "bold")
        txt("#{s[:count]} items", x + 42, 31, size: 9, color: TEXT)
        if i < stages.size - 1
          ax = x + bw + gap / 2
          txt("→", ax - 8, 24, size: 12, color: CYAN, width: 16, align: "center")
        end
      end
      chart_w = w - 120
      line_chart(12, 76, chart_w, h - 84, @store.series_labels, @store.series)
      legend(chart_w + 30, 92, @store.series)
    end

    # ---- System health -------------------------------------------------

    def draw_health_body(w, h)
      gauges = [[:cpu, "CPU", CYAN], [:memory, "Memory", TEAL], [:network, "Network", CYAN], [:storage, "Storage", TEAL]]
      slot_w = w / gauges.size
      gauges.each_with_index do |(key, name, color), i|
        donut(slot_w * i + slot_w / 2, 46, 34, @store.health[key], color, label: name)
      end
      hl = @store.health
      metrics = [
        ["▤", "Total Uptime",  uptime_text(hl[:uptime_s])],
        ["☀", "Response Time", "#{hl[:response_ms]}ms"],
        ["◷", "Error Rate",    "#{hl[:error_rate]}%"]
      ]
      mw = (w - 32) / metrics.size
      metrics.each_with_index do |(glyph, name, value), i|
        x = 14 + i * mw
        box(x, 118, mw - 6, [h - 126, 60].min, fill: col(PANEL2), stroke: col(CYAN, 0.12), curve: 7)
        txt(glyph, x + 12, 128, size: 11, color: TEAL)
        txt(name, x + 30, 128, size: 9, color: MUTED)
        txt(value, x + 12, 148, size: 13, color: TEXT, weight: "bold")
      end
    end

    def uptime_text(secs)
      d = secs / 86_400
      hh = (secs % 86_400) / 3600
      "#{d}d #{hh}h"
    end

    # ---- Recent activity -----------------------------------------------

    def draw_recent_body(w, h)
      row_h = 27
      rows = [(h - 4) / row_h, @store.events.size].min
      @store.events.first(rows).each_with_index do |e, i|
        y = 2 + i * row_h
        bot = @store.bot(e.bot_id)
        avatar(14, y + 3, bot ? bot.color : CYAN, bot ? bot.glyph : "?", 20)
        txt(bot ? bot.name : e.bot_id.to_s, 42, y + 5, size: 9, color: TEXT, weight: "bold")
        dot(150, y + 10, bot ? bot.color : CYAN, 5)
        txt(clip(e.message, (w - 240) / 6), 160, y + 5, size: 9, color: TEXT)
        txt(Store.ago(e.at), w - 70, y + 5, size: 9, color: MUTED, width: 58, align: "right")
      end
    end

    # ---- Agent details -------------------------------------------------

    def draw_agent_body(w, h)
      bot = @store.selected_bot
      d = agent_detail_for(bot)
      avatar(16, 6, bot.color, bot.glyph, 44)
      txt(bot.name, 72, 6, size: 11, color: TEXT, weight: "bold")
      status_pill(72, 25, bot.status)
      txt("#{bot.tasks} active tasks", 72, 38, size: 9, color: MUTED)
      txt("☰", w - 26, 6, size: 11, color: MUTED)

      col_w = ((w - 32) * 0.55).to_i
      box(12, 60, col_w, [h - 68, 100].min, fill: col(PANEL2), stroke: col(CYAN, 0.12), curve: 7)
      label("Current Task", 22, 68, size: 9, color: MUTED)
      txt(clip(d[:task], 30), 22, 82, size: 9, color: TEXT)
      hbar(22, 102, col_w - 56, 6, d[:progress], bot.color)
      txt("#{d[:progress]}%", 22 + col_w - 50, 96, size: 9, color: TEXT, width: 34, align: "right")
      label("Started", 22, 118, size: 9, color: MUTED)
      txt(Store.ago(d[:started_at]), 80, 118, size: 9, color: TEXT)
      label("Model", 22, 136, size: 9, color: MUTED)
      txt(d[:model], 80, 136, size: 9, color: TEXT)

      cx = 22 + col_w
      label("Capabilities", cx, 70, size: 9, color: MUTED)
      Array(d[:capabilities]).each_with_index do |cap, i|
        txt(CHECK, cx, 88 + i * 18, size: 9, color: TEAL)
        txt(cap, cx + 14, 88 + i * 18, size: 9, color: TEXT)
      end
    end

    # Merge the store's agent detail with the selected bot's live activity so
    # clicking a bot in the fleet shows what it is doing right now.
    def agent_detail_for(bot)
      d = @store.agent_detail.dup
      act = @store.activity.find { |a| a.bot_id == bot.id && a.status != "Pending" }
      if act && d[:bot_id] != bot.id
        d[:task] = act.task
        d[:progress] = act.progress
        d[:started_at] = act.started_at
      end
      d
    end

    # ---- Logs ----------------------------------------------------------

    def draw_logs_body(w, h)
      row_h = 19
      rows = [(h - 6) / row_h, @store.logs.size].min
      @store.logs.first(rows).each_with_index do |l, i|
        y = 4 + i * row_h
        txt(l.time.strftime("%H:%M"), 14, y, size: 9, color: MUTED, mono: true)
        txt("[#{l.level}]", 54, y, size: 9, color: Theme.level_color(l.level), mono: true)
        txt(clip(l.message, (w - 120) / 6), 110, y, size: 9, color: TEXT)
      end
    end

    # ---- Reports -------------------------------------------------------

    def draw_reports_body(w, h)
      row_h = 33
      rows = [(h - 4) / row_h, @store.reports.size].min
      @store.reports.first(rows).each_with_index do |r, i|
        y = 2 + i * row_h
        square_icon(14, y + 3, r.color, r.kind == "PDF" ? "☰" : "∴", 24)
        txt(r.name, 48, y + 2, size: 9, color: TEXT, weight: "bold")
        txt(r.at.strftime("%b %-d, %Y %H:%M"), 48, y + 17, size: 8, color: MUTED)
      end
    end

    # ---- Settings (no counterpart in the mock-up; hosts window controls) --

    def draw_settings_body(w, _h)
      rows = [
        ["Window",         "Borderless (decorated: false), #{Layout::WIDTH}x#{Layout::HEIGHT}"],
        ["Comms channel",  @channel.name],
        ["Refresh",        "every #{Hub::REFRESH_SECONDS}s"],
        ["Shoes",          (defined?(Shoes::RELEASE_NAME) ? "#{Shoes::RELEASE_NAME} #{Shoes::VERSION rescue ''}" : "unknown")],
        ["Ruby",           RUBY_VERSION],
        ["Platform",       RUBY_PLATFORM]
      ]
      rows.each_with_index do |(k, v), i|
        y = 10 + i * 24
        label(k, 16, y, size: 9, color: MUTED)
        txt(v, 150, y, size: 9, color: TEXT)
      end
      y = 10 + rows.size * 24 + 10
      txt("Window", 16, y, size: 9, color: MUTED)
      b1 = txt("[ Toggle title bar ]", 150, y, size: 9, color: CYAN)
      b1.click { toggle_decorations }
      b2 = txt("[ Toggle fullscreen ]", 300, y, size: 9, color: CYAN)
      b2.click { toggle_fullscreen }
      b3 = txt("[ Quit ]", 460, y, size: 9, color: RED)
      b3.click { quit_app }
      txt("Drag the header bar to move the window.", 16, y + 28, size: 9, color: DIM, width: w - 32)
    end
  end
end
