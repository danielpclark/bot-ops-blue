# frozen_string_literal: true

module BotOps
  # Application lifecycle: builds the chrome (header, sidebar), hosts the
  # current page, and runs the refresh loop that drains the comms channel.
  module Hub
    include Theme

    REFRESH_SECONDS = 2
    STAT_WIDTHS = [104, 96, 126, 158, 116].freeze

    def boot(store = nil, channel = nil)
      @store   = store || Store.new
      @channel = channel || Comms::SimulatedChannel.new
      @panels  = {}
      @nav_slots = {}

      background col(BG)
      draw_header
      draw_sidebar
      @page_slot = stack(left: Layout::CONTENT_X, top: Layout::CONTENT_Y,
                         width: Layout::CONTENT_W, height: Layout::CONTENT_H) do
        draw_page(@store.page)
      end

      @channel.start(@store)
      @timer = every(REFRESH_SECONDS) { tick }
      self
    end

    # One refresh cycle: drain comms, apply to the store, redraw live panels.
    def tick
      events = @channel.poll(@store)
      @store.apply_all(events)
      refresh
    end

    def refresh
      @clock.text = clock_text if @clock
      @panels.each do |name, slot|
        next unless Hub.live_panel?(name)
        w, hgt = @panel_sizes[name]
        slot.clear { send("draw_#{name}_body", w, hgt) }
      end
    end

    STATIC_PANELS = [:workflows, :reports, :settings].freeze

    def self.live_panel?(name)
      !STATIC_PANELS.include?(name)
    end

    # ---- header --------------------------------------------------------

    def draw_header
      w = Layout::WIDTH
      hh = Layout::HEADER_H
      header = stack(left: 0, top: 0, width: w, height: hh) do
        background col(BG)
        rect(left: 12, top: 6, width: w - 24, height: hh - 12, curve: 8, fill: col(PANEL), stroke: col(CYAN, 0.3))
        line(60, 7, w - 60, 7, stroke: col(CYAN, 0.45), strokewidth: 1)

        # logo
        oval(left: 36, top: 22, width: 44, height: 44, fill: col(CYAN, 0.08), stroke: col(CYAN, 0.9), strokewidth: 1)
        oval(left: 44, top: 30, width: 28, height: 28, fill: col(CYAN, 0.0), stroke: col(CYAN, 0.5), strokewidth: 1)
        txt("⌘", 36, 34, size: 14, color: CYAN, width: 44, align: "center")

        txt("BOT OPS BLUE", 108, 22, size: 20, color: CYAN, weight: "bold", kerning: 3)
        txt("AUTOMATE   /   CREATE   /   SCALE", 110, 52, size: 9, color: MUTED, kerning: 2)
        vline(432, 18, hh - 18, col(CYAN, 0.25))

        x = 452
        @store.stats.each_with_index do |s, i|
          label(s.label, x, 24, size: 8, color: MUTED, kerning: 1)
          txt(s.value, x, 40, size: 20, color: TEXT, weight: "bold")
          arrow = s.delta_dir == :down ? "↓" : "↑"
          off = 10 + s.value.length * 12
          txt("#{arrow} #{s.delta}", x + off, 46, size: 9, color: s.delta_color)
          x += STAT_WIDTHS[i] || 110
          vline(x - 10, 22, hh - 22, col(CYAN, 0.12))
        end

        glow_dot(1136, 33, @store.system_online ? GREEN : RED, 7)
        txt(@store.system_online ? "SYSTEM ONLINE" : "SYSTEM OFFLINE", 1150, 28, size: 9, color: @store.system_online ? GREEN : RED, weight: "bold")
        @clock = txt(clock_text, 1150, 48, size: 9, color: TEXT)
        vline(1312, 20, hh - 20, col(CYAN, 0.25))
        txt(@store.quote, 1330, 22, size: 9, color: TEAL, width: 176)

        # window controls (borderless window has none of its own)
        [["▣", 1468, :toggle_decorations], ["⤢", 1486, :toggle_fullscreen], ["✕", 1504, :quit_app]].each do |glyph, bx, action|
          b = txt(glyph, bx, 8, size: 9, color: MUTED, width: 14, align: "center")
          b.click { send(action) }
        end
      end
      install_drag(header)
    end

    def clock_text
      Time.now.strftime("%b %-d, %Y  %H:%M")
    end

    # Click-and-drag anywhere on the header to move the borderless window.
    def install_drag(slot)
      @drag = nil
      slot.click do |button, left, top|
        @drag = [left, top] if button == 1
      end
      slot.motion do |left, top|
        next unless @drag
        if mouse[0] == 1
          dx = left - @drag[0]
          dy = top - @drag[1]
          app.move(app.left + dx, app.top + dy) if dx != 0 || dy != 0
        else
          @drag = nil
        end
      end
      slot.release { @drag = nil }
    end

    def toggle_decorations
      app.decorated = !app.decorated
    end

    def toggle_fullscreen
      app.fullscreen = !app.fullscreen
    end

    def quit_app
      @channel.stop
      Shoes.quit
    end

    # ---- sidebar -------------------------------------------------------

    def draw_sidebar
      x = Layout::SIDEBAR_X
      w = Layout::SIDEBAR_W
      @sidebar = stack(left: x, top: Layout::CONTENT_Y, width: w, height: Layout::CONTENT_H) do
        draw_sidebar_body(w)
      end
    end

    def draw_sidebar_body(w)
      background col(PANEL), curve: 8
      border col(CYAN, 0.3), strokewidth: 1, curve: 8
      Layout::NAV.each_with_index do |(key, name, glyph), i|
        y = 6 + i * 62
        active = @store.page == key
        item = stack(left: 4, top: y, width: w - 8, height: 58) do
          if active
            background col(CYAN, 0.1), curve: 6
            border col(CYAN, 0.6), strokewidth: 1, curve: 6
          end
          txt(glyph, 0, 12, size: 15, color: active ? CYAN : MUTED, width: w - 8, align: "center")
          txt(name, 0, 36, size: 8, color: active ? CYAN : MUTED, width: w - 8, align: "center")
        end
        item.click { show_page(key) }
        @nav_slots[key] = item
      end
    end

    def show_page(key)
      return if @store.page == key
      @store.page = key
      @sidebar.clear { draw_sidebar_body(Layout::SIDEBAR_W) }
      @panels = {}
      @page_slot.clear { draw_page(key) }
    end

    # ---- pages ---------------------------------------------------------

    def place(name, title, geom, opts = {})
      x, y, w, h = geom
      x -= Layout::CONTENT_X
      y -= Layout::CONTENT_Y
      @panel_sizes ||= {}
      body_h = h - Layout::PANEL_TITLE_H
      @panel_sizes[name] = [w, body_h]
      @panels[name] = panel(x, y, w, h, opts.merge(title: title)) { send("draw_#{name}_body", w, body_h) }
    end

    def draw_page(key)
      @panel_sizes = {}
      cw = Layout::CONTENT_W
      ch = Layout::CONTENT_H
      cx = Layout::CONTENT_X
      cy = Layout::CONTENT_Y
      half = (cw - Layout::GAP) / 2
      case key
      when :bots
        place(:fleet, "BOT FLEET", [cx, cy, half, ch], right: "#{@store.fleet_total} total")
        place(:agent, "AGENT DETAILS", [cx + half + Layout::GAP, cy, half, 300])
        place(:recent, "RECENT ACTIVITY", [cx + half + Layout::GAP, cy + 312, half, ch - 312])
      when :workflows
        place(:workflows, "WORKFLOWS", [cx, cy, cw, ch], right: "● Active", right_color: TEAL)
      when :queue
        place(:queue, "TASK QUEUE", [cx, cy, cw, ch])
      when :data
        place(:pipeline, "CURRENT PIPELINE", [cx, cy, cw - 300 - Layout::GAP, ch])
        place(:reports, "RECENT REPORTS", [cx + cw - 300, cy, 300, ch], right: "View All")
      when :logs
        place(:logs, "RECENT LOGS", [cx, cy, cw, ch], right: "View All")
      when :analytics
        place(:health, "SYSTEM HEALTH", [cx, cy, half, 300])
        place(:pipeline, "CURRENT PIPELINE", [cx + half + Layout::GAP, cy, half, 300])
        place(:activity, "LIVE BOT ACTIVITY", [cx, cy + 312, cw, ch - 312])
      when :settings
        place(:settings, "SETTINGS", [cx, cy, cw, ch])
      else
        draw_overview
      end
    end

    def draw_overview
      place(:fleet,     "BOT FLEET",         Layout::FLEET, right: "#{@store.fleet_total} total")
      place(:activity,  "LIVE BOT ACTIVITY", Layout::ACTIVITY)
      place(:workflows, "WORKFLOWS",         Layout::WORKFLOWS, right: "● Active", right_color: TEAL)
      place(:queue,     "TASK QUEUE",        Layout::QUEUE)
      place(:pipeline,  "CURRENT PIPELINE",  Layout::PIPELINE)
      place(:health,    "SYSTEM HEALTH",     Layout::HEALTH)
      place(:recent,    "RECENT ACTIVITY",   Layout::RECENT)
      place(:agent,     "AGENT DETAILS",     Layout::AGENT)
      place(:logs,      "RECENT LOGS",       Layout::LOGS, right: "View All")
      place(:reports,   "RECENT REPORTS",    Layout::REPORTS, right: "View All")
    end

    # ---- interactions --------------------------------------------------

    def set_activity_tab(key)
      @store.activity_tab = key
      redraw_panel(:activity)
    end

    def set_queue_filter(key)
      @store.queue_filter = key
      redraw_panel(:queue)
    end

    def select_bot(id)
      @store.selected_bot_id = id
      redraw_panel(:agent)
    end

    def redraw_panel(name)
      slot = @panels[name]
      return unless slot
      w, hgt = @panel_sizes[name]
      slot.clear { send("draw_#{name}_body", w, hgt) }
    end
  end
end
