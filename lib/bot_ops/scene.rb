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
      draw_resize_grip if resize_grip
      draw_overlay(@store.overlay) if @store.overlay
      @c
    end

    # ---- header --------------------------------------------------------

    def draw_header
      w = @width
      dx = w - Layout::WIDTH # right-hand header items stay pinned to the right edge
      hh = Layout::HEADER_H
      @c.rect(12, 6, w - 24, hh - 12, curve: 8, fill: col(PANEL))
      electric_frame(12, 6, w - 24, hh - 12, curve: 8)

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
      draw_window_controls
    end

    # ---- window controls -------------------------------------------------
    #
    # A borderless window has none of its own: small muted icons in the top
    # right corner, 18pt apart, each with a 20pt click area, drawn as shapes
    # rather than font glyphs (the old ⤢ glyph rendered as an empty box).

    CONTROL_SIZE = 10
    CONTROL_HIT = 20
    CONTROL_Y = 9
    CONTROLS = [[:minimize, 1470], [:toggle_fullscreen, 1488], [:quit, 1506]].freeze

    # [[action, x, y, size], ...]: each icon's box in window coordinates.
    def window_controls
      dx = @width - Layout::WIDTH
      CONTROLS.map { |action, x| [action, dx + x, CONTROL_Y, CONTROL_SIZE] }
    end

    def draw_window_controls
      pad = (CONTROL_HIT - CONTROL_SIZE) / 2
      window_controls.each do |action, x, y, s|
        send("icon_#{action}", x, y, s, col(MUTED))
        @c.hit(x - pad, y - pad, CONTROL_HIT, CONTROL_HIT) { @host.send(action) }
      end
    end

    def icon_minimize(x, y, s, c)
      @c.line(x, y + s - 1, x + s, y + s - 1, stroke: c, strokewidth: 1.5)
    end

    # Corner brackets: at the corners pointing in to go fullscreen, pulled
    # toward the middle and pointing out to leave it.
    def icon_toggle_fullscreen(x, y, s, c)
      inward = @host.respond_to?(:fullscreen?) && @host.fullscreen?
      l = 3.0
      [[x, y, 1, 1], [x + s, y, -1, 1], [x, y + s, 1, -1], [x + s, y + s, -1, -1]].each do |cx, cy, sx, sy|
        if inward
          px = cx + sx * l
          py = cy + sy * l
          @c.line(px, py, cx, py, stroke: c, strokewidth: 1.5)
          @c.line(px, py, px, cy, stroke: c, strokewidth: 1.5)
        else
          @c.line(cx, cy, cx + sx * l, cy, stroke: c, strokewidth: 1.5)
          @c.line(cx, cy, cx, cy + sy * l, stroke: c, strokewidth: 1.5)
        end
      end
    end

    def icon_quit(x, y, s, c)
      @c.line(x, y, x + s, y + s, stroke: c, strokewidth: 1.5)
      @c.line(x + s, y, x, y + s, stroke: c, strokewidth: 1.5)
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
        @c.rect(0, 0, w, Layout.content_h(@height), curve: 8, fill: col(PANEL))
        electric_frame(0, 0, w, Layout.content_h(@height), curve: 8)
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

    # ---- resize grip -------------------------------------------------------

    GRIP = 16

    # The bottom-right corner that resizes the window ([x, y, w, h]); none in
    # fullscreen.
    def resize_grip
      return nil if @host.respond_to?(:fullscreen?) && @host.fullscreen?
      [@width - GRIP, @height - GRIP, GRIP, GRIP]
    end

    # Three short diagonal strokes, the usual corner grip.
    def draw_resize_grip
      x, y, = resize_grip
      [4, 8, 12].each do |d|
        @c.line(x + GRIP - 3, y + GRIP - 3 - d, x + GRIP - 3 - d, y + GRIP - 3, stroke: col(MUTED, 0.7), strokewidth: 1.2)
      end
    end

    # ---- detail overlay ----------------------------------------------------

    def open_overlay(overlay)
      @store.overlay = overlay
      @host.invalidate
    end

    def close_overlay
      @store.overlay = nil
      @host.invalidate
    end

    # Mouse wheel / trackpad, in lines. True when something used it.
    def scroll(lines)
      return false unless @store.overlay && lines != 0
      @store.overlay.scroll_by(lines)
      @host.invalidate
      true
    end

    # Esc closes an open overlay. True when it did.
    def escape
      return false unless @store.overlay
      close_overlay
      true
    end

    OVERLAY_TEXT = 10
    OVERLAY_LINE = 16
    OVERLAY_CHAR = OVERLAY_TEXT * 0.602 # DejaVu Sans Mono's advance

    # The box: centred, dimmed backdrop, electric frame, title, close X, and a
    # scrolling window of the content's lines with a scrollbar when it
    # overflows. A click on the backdrop closes it; clicks inside don't.
    def draw_overlay(o)
      w, h = @width, @height
      @c.rect(0, 0, w, h, fill: col(BG, 0.78))
      @c.hit(0, 0, w, h) { close_overlay }

      bw = [[w - 260, 1040].min, 560].max
      bh = [[h - 200, 780].min, 320].max
      bx = (w - bw) / 2
      by = (h - bh) / 2
      @c.rect(bx, by, bw, bh, curve: 9, fill: col(PANEL))
      electric_frame(bx, by, bw, bh, curve: 9)
      @c.hit(bx, by, bw, bh) {}

      txt(clip(o.title, (bw - 90) / 8), bx + 22, by + 14, size: 13, color: TEXT, weight: :bold)
      txt(clip(o.subtitle, (bw - 60) / 5.5), bx + 22, by + 36, size: 9, color: MUTED) if o.subtitle
      cx = bx + bw - 34
      @c.line(cx, by + 16, cx + 12, by + 28, stroke: col(MUTED), strokewidth: 1.5)
      @c.line(cx + 12, by + 16, cx, by + 28, stroke: col(MUTED), strokewidth: 1.5)
      @c.hit(cx - 6, by + 10, 24, 24) { close_overlay }
      fade_line(bx + 14, bx + bw - 14, by + 56, BOLT)

      top = by + 68
      body_h = bh - 68 - 30
      visible = body_h / OVERLAY_LINE
      lines = o.lines(((bw - 64) / OVERLAY_CHAR).floor)
      o.offset = o.offset.clamp(0, [lines.size - visible, 0].max)
      lines[o.offset, visible].to_a.each_with_index do |(style, a, b, label_w), i|
        y = top + i * OVERLAY_LINE
        case style
        when :field
          txt(a, bx + 24, y, size: OVERLAY_TEXT, color: MUTED, mono: true)
          txt(b, bx + 24 + label_w * OVERLAY_CHAR, y, size: OVERLAY_TEXT, color: TEXT, mono: true)
        when :heading then txt(a, bx + 24, y, size: OVERLAY_TEXT, color: CYAN, weight: :bold)
        when :note then txt(a, bx + 24, y, size: OVERLAY_TEXT, color: DIM, mono: true)
        when :blank then nil
        else txt(a, bx + 24, y, size: OVERLAY_TEXT, color: TEXT, mono: true)
        end
      end

      if lines.size > visible
        track_h = body_h - 4
        thumb_h = [track_h * visible / lines.size, 24].max
        thumb_y = top + (track_h - thumb_h) * o.offset / (lines.size - visible).to_f
        @c.rect(bx + bw - 16, top, 4, track_h, curve: 2, fill: col(TRACK))
        @c.rect(bx + bw - 16, thumb_y, 4, thumb_h, curve: 2, fill: col(BOLT, 0.9))
      end
      hint = lines.size > visible ? "Scroll for more  ·  " : ""
      txt("#{hint}Esc, X or a click outside closes", bx + 24, by + bh - 22, size: 8, color: DIM)
    end

    # Opens a cloud session's page at claude.ai in the browser.
    def open_session_url(url)
      return unless url.to_s.match?(CloudFeed::SESSION_URL) && @host.respond_to?(:open_url)
      @host.open_url(url)
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
    attr_accessor :fullscreen

    def minimize; @actions << :minimize; end
    def fullscreen?; @fullscreen ? true : false; end
    def toggle_decorations; @actions << :toggle_decorations; end
    def toggle_fullscreen; @actions << :toggle_fullscreen; end
    def quit; @actions << :quit; end
    def open_url(url); @actions << [:open_url, url]; end
    def toolkit_name; "preview"; end
    def channel_name; "preview"; end
  end
end
