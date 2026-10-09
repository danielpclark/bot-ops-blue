# frozen_string_literal: true

module BotOps
  # Builds the whole dashboard into a Canvas from the Store, and handles the
  # interactions that come back from clickable regions. It knows nothing about
  # the GUI toolkit; the host passed in provides window-level actions.
  #
  # Host protocol: #invalidate, #toggle_decorations, #toggle_fullscreen,
  # #quit, #toolkit_name, #channel_name.
  class Scene
    include Theme
    include Widgets
    include Panels

    REFRESH_SECONDS = 2
    STAT_WIDTHS = [104, 96, 126, 158, 116].freeze
    STATIC_PANELS = [:workflows, :reports, :settings].freeze

    attr_reader :store, :host

    def initialize(store, host)
      @store = store
      @host = host
    end

    # Fill a canvas with the current frame.
    def build(canvas = Canvas.new(Layout::WIDTH, Layout::HEIGHT))
      @c = canvas
      @c.rect(0, 0, Layout::WIDTH, Layout::HEIGHT, fill: col(BG))
      draw_header
      draw_sidebar
      @c.group(Layout::CONTENT_X, Layout::CONTENT_Y) { draw_page(@store.page) }
      @c
    end

    # ---- header --------------------------------------------------------

    def draw_header
      w = Layout::WIDTH
      hh = Layout::HEADER_H
      @c.rect(12, 6, w - 24, hh - 12, curve: 8, fill: col(PANEL), stroke: col(CYAN, 0.3))
      @c.line(60, 7, w - 60, 7, stroke: col(CYAN, 0.45))

      # logo
      @c.circle(58, 44, 22, fill: col(CYAN, 0.08), stroke: col(CYAN, 0.9))
      @c.circle(58, 44, 14, stroke: col(CYAN, 0.5))
      txt("⌘", 36, 34, size: 14, color: CYAN, width: 44, align: :center)

      txt("BOT OPS BLUE", 108, 22, size: 20, color: CYAN, weight: :bold, kerning: 3)
      txt("AUTOMATE   /   CREATE   /   SCALE", 110, 52, size: 9, color: MUTED, kerning: 2)
      vline(432, 18, hh - 18, col(CYAN, 0.25))

      x = 452
      @store.stats.each_with_index do |s, i|
        label(s.label, x, 24, size: 8, color: MUTED, kerning: 1)
        txt(s.value, x, 40, size: 20, color: TEXT, weight: :bold)
        arrow = s.delta_dir == :down ? "↓" : "↑"
        off = 10 + s.value.length * 12
        txt("#{arrow} #{s.delta}", x + off, 46, size: 9, color: s.delta_color)
        x += STAT_WIDTHS[i] || 110
        vline(x - 10, 22, hh - 22, col(CYAN, 0.12))
      end

      online = @store.system_online
      glow_dot(1136, 33, col(online ? GREEN : RED), 7)
      txt(online ? "SYSTEM ONLINE" : "SYSTEM OFFLINE", 1150, 28, size: 9, color: online ? GREEN : RED, weight: :bold)
      txt(clock_text, 1150, 48, size: 9, color: TEXT)
      vline(1312, 20, hh - 20, col(CYAN, 0.25))
      txt(@store.quote, 1330, 22, size: 9, color: TEAL, width: 176)

      # window controls (a borderless window has none of its own)
      [["▣", 1468, :toggle_decorations], ["⤢", 1486, :toggle_fullscreen], ["✕", 1504, :quit]].each do |glyph, bx, action|
        txt(glyph, bx, 8, size: 9, color: MUTED, width: 14, align: :center)
        @c.hit(bx - 3, 4, 20, 20) { @host.send(action) }
      end
    end

    def clock_text
      Time.now.strftime("%b %-d, %Y  %H:%M")
    end

    # Header area that drags the window (everything in the header except hits).
    def drag_region?(x, y)
      y < Layout::HEADER_H && @c.hit_at(x, y).nil?
    end

    # ---- sidebar -------------------------------------------------------

    def draw_sidebar
      x = Layout::SIDEBAR_X
      w = Layout::SIDEBAR_W
      @c.group(x, Layout::CONTENT_Y) do
        @c.rect(0, 0, w, Layout::CONTENT_H, curve: 8, fill: col(PANEL), stroke: col(CYAN, 0.3))
        Layout::NAV.each_with_index do |(key, name, glyph), i|
          y = 6 + i * 62
          active = @store.page == key
          if active
            @c.rect(4, y, w - 8, 58, curve: 6, fill: col(CYAN, 0.1), stroke: col(CYAN, 0.6))
          end
          txt(glyph, 4, y + 12, size: 15, color: active ? CYAN : MUTED, width: w - 8, align: :center)
          txt(name, 4, y + 36, size: 8, color: active ? CYAN : MUTED, width: w - 8, align: :center)
          @c.hit(4, y, w - 8, 58) { show_page(key) }
        end
      end
    end

    # ---- pages ---------------------------------------------------------

    def place(name, title, geom, opts = {})
      x, y, w, h = geom
      body_h = h - Layout::PANEL_TITLE_H
      panel(x - Layout::CONTENT_X, y - Layout::CONTENT_Y, w, h, opts.merge(title: title)) do
        send("draw_#{name}_body", w, body_h)
      end
    end

    def draw_page(key)
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

    def show_page(key)
      return if @store.page == key
      @store.page = key
      @host.invalidate
    end

    def set_activity_tab(key)
      @store.activity_tab = key
      @host.invalidate
    end

    def set_queue_filter(key)
      @store.queue_filter = key
      @host.invalidate
    end

    def select_bot(id)
      @store.selected_bot_id = id
      @host.invalidate
    end

    # Dispatch a click at window coordinates. Returns true when a region
    # handled it.
    def click(x, y)
      h = @c && @c.hit_at(x, y)
      return false unless h
      h.handler.call
      true
    end
  end
end

module BotOps
  # Minimal host for tests and previews: records window actions, no toolkit.
  class PreviewHost
    attr_reader :actions, :invalidations

    def initialize
      @actions = []
      @invalidations = 0
    end

    def invalidate; @invalidations += 1; end
    def toggle_decorations; @actions << :toggle_decorations; end
    def toggle_fullscreen; @actions << :toggle_fullscreen; end
    def quit; @actions << :quit; end
    def toolkit_name; "preview"; end
    def channel_name; "SimulatedChannel"; end
  end
end
