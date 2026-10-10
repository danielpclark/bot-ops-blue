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
    STAT_WIDTHS = [112, 100, 120, 140, 128].freeze

    attr_reader :store, :host, :width, :height

    def initialize(store, host)
      @store = store
      @host = host
      resize(Layout::WIDTH, Layout::HEIGHT)
    end

    # Lays out for a window of +w+ x +h+ points (never below the design size).
    def resize(w, h)
      @width = [w.to_i, Layout::WIDTH].max
      @height = [h.to_i, Layout::HEIGHT].max
    end

    # Fill a canvas with the current frame.
    def build(canvas = Canvas.new(@width, @height))
      @c = canvas
      @c.rect(0, 0, @width, @height, fill: col(BG))
      draw_header
      draw_sidebar
      @c.group(Layout::CONTENT_X, Layout::CONTENT_Y) { draw_page(@store.page) }
      @c
    end

    # ---- header --------------------------------------------------------

    def draw_header
      w = @width
      dx = w - Layout::WIDTH # right-hand header items stay pinned to the right edge
      hh = Layout::HEADER_H
      @c.rect(12, 6, w - 24, hh - 12, curve: 8, fill: col(PANEL), stroke: col(CYAN, 0.3))
      @c.line(60, 7, w - 60, 7, stroke: col(CYAN, 0.45))

      # logo: the bot portrait in a round, glowing frame like a profile photo
      @c.circle(60, 43, 33, fill: col(CYAN, 0.10))
      @c.image_circle("logo", 60, 43, 28)
      @c.circle(60, 43, 28.5, stroke: col(CYAN, 0.95), strokewidth: 2)
      @c.circle(60, 43, 32, stroke: col(BLUE, 0.45))

      txt("BOT OPS BLUE", 108, 22, size: 20, color: CYAN, weight: :bold, kerning: 3)
      txt("AUTOMATE   /   CREATE   /   SCALE", 110, 52, size: 9, color: MUTED, kerning: 2)
      vline(432, 18, hh - 18, col(CYAN, 0.25))

      x = 452
      @store.stats.each_with_index do |s, i|
        label(s.label, x, 24, size: 8, color: MUTED, kerning: 1)
        txt(s.value, x, 40, size: 20, color: TEXT, weight: :bold)
        off = 10 + s.value.length * 12
        txt(clip(s.note, (STAT_WIDTHS[i] - off - 12) / 5), x + off, 46, size: 8, color: s.note_color)
        x += STAT_WIDTHS[i] || 110
        vline(x - 10, 22, hh - 22, col(CYAN, 0.12))
      end

      online = @store.online_machines.size
      ok = online.positive? && @store.probe_error.nil?
      status = if @store.probe_error then "PROBE ERROR"
               elsif online.zero? then "WAITING FOR DATA"
               else "#{online} MACHINE#{'S' unless online == 1} ONLINE"
               end
      glow_dot(dx + 1136, 33, col(ok ? GREEN : (online.zero? ? YELLOW : RED)), 7)
      txt(status, dx + 1150, 28, size: 9, color: ok ? GREEN : (online.zero? ? YELLOW : RED), weight: :bold)
      txt(clock_text, dx + 1150, 48, size: 9, color: TEXT)
      vline(dx + 1312, 20, hh - 20, col(CYAN, 0.25))
      txt(@store.collector_status, dx + 1330, 22, size: 9, color: TEAL, width: 128)

      # window controls (a borderless window has none of its own)
      [["▣", 1468, :toggle_decorations], ["⤢", 1486, :toggle_fullscreen], ["✕", 1504, :quit]].each do |glyph, bx, action|
        txt(glyph, dx + bx, 8, size: 9, color: MUTED, width: 14, align: :center)
        @c.hit(dx + bx - 3, 4, 20, 20) { @host.send(action) }
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
        @c.rect(0, 0, w, Layout.content_h(@height), curve: 8, fill: col(PANEL), stroke: col(CYAN, 0.3))
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
      cw = Layout.content_w(@width)
      ch = Layout.content_h(@height)
      cx = Layout::CONTENT_X
      cy = Layout::CONTENT_Y
      half = (cw - Layout::GAP) / 2
      case key
      when :sessions
        place(:sessions, "CLAUDE SESSIONS", [cx, cy, half, ch], right: "#{@store.sessions.size} live · #{@store.recent_sessions.size} earlier")
        place(:detail, "SESSION DETAILS", [cx + half + Layout::GAP, cy, half, 300])
        place(:prompts, "RECENT PROMPTS", [cx + half + Layout::GAP, cy + 312, half, ch - 312])
      when :projects
        place(:projects, "PROJECTS · 24H", [cx, cy, cw, ch], right: "#{@store.projects.size} active", right_color: TEAL)
      when :tools
        place(:tools, "TOOL CALLS", [cx, cy, cw, ch])
      when :usage
        place(:usage, "USAGE", [cx, cy, cw - 300 - Layout::GAP, ch])
        place(:machines, "MACHINES", [cx + cw - 300, cy, 300, ch])
      when :logs
        place(:log, "EVENT LOG", [cx, cy, cw, ch], right: "prompts · tools · errors")
      when :machines
        place(:health, "SYSTEM HEALTH · #{health_machine&.dig('host')}", [cx, cy, half, 300])
        place(:machines, "MACHINES", [cx + half + Layout::GAP, cy, half, 300])
        place(:live, "LIVE ACTIVITY", [cx, cy + 312, cw, ch - 312])
      when :settings
        place(:settings, "SETTINGS", [cx, cy, cw, ch])
      else
        draw_overview
      end
    end

    def fit(rect)
      Layout.fit(rect, @width, @height)
    end

    def draw_overview
      place(:sessions, "CLAUDE SESSIONS",  fit(Layout::FLEET), right: "#{@store.sessions.size} live · #{@store.recent_sessions.size} earlier")
      place(:live,     "LIVE ACTIVITY",    fit(Layout::ACTIVITY))
      place(:projects, "PROJECTS · 24H",   fit(Layout::WORKFLOWS), right: "#{@store.projects.size} active", right_color: TEAL)
      place(:tools,    "TOOL CALLS", fit(Layout::QUEUE))
      place(:usage,    "USAGE",            fit(Layout::PIPELINE))
      place(:health,   "SYSTEM HEALTH · #{health_machine&.dig('host')}", fit(Layout::HEALTH))
      place(:prompts,  "RECENT PROMPTS",   fit(Layout::RECENT))
      place(:detail,   "SESSION DETAILS",  fit(Layout::AGENT))
      place(:log,      "EVENT LOG",        fit(Layout::LOGS))
      place(:machines, "MACHINES",         fit(Layout::REPORTS), right: "#{@store.online_machines.size} online")
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

    def set_tool_filter(key)
      @store.tool_filter = key
      @host.invalidate
    end

    def select_session(id)
      @store.selected_session_id = id
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
    def channel_name; "preview"; end
  end
end
