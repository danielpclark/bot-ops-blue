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
    # Width of one 10pt monospace character as the native side renders it at
    # the current zoom (pixel rounding makes it differ from the font's 0.602em).
    attr_writer :mono_char

    def initialize(store, host)
      @store = store
      @host = host
      @theme_menu = false
      resize(Layout::WIDTH, Layout::HEIGHT)
    end

    # ---- theme (Settings page) -----------------------------------------

    def theme_menu?
      @theme_menu
    end

    def toggle_theme_menu
      @theme_menu = !@theme_menu
      @host.invalidate
    end

    def close_theme_menu
      @theme_menu = false
      @host.invalidate
    end

    # Switches to the theme +slug+ and remembers it in prefs. A theme that
    # fails to load leaves the current one in place (Theme.use says why).
    def choose_theme(slug)
      @store.theme = slug if Theme.use(slug)
      @theme_menu = false
      @host.invalidate
    end

    # Lays out for a window of +w+ x +h+ points (never below the design size).
    def resize(w, h)
      @width = [w.to_i, Layout::WIDTH].max
      @height = [h.to_i, Layout::HEIGHT].max
    end

    # Fill a canvas with the current frame.
    def build(canvas = Canvas.new(@width, @height))
      @c = canvas
      @c.rect(0, 0, @width, @height, fill: col(theme.bg))
      draw_header
      draw_sidebar
      @c.group(Layout::CONTENT_X, Layout::CONTENT_Y) { draw_page(@store.page) }
      draw_resize_grip if resize_grip
      draw_overlay(@store.overlay) if @store.overlay
      @c
    end

    # ---- header --------------------------------------------------------

    STAT_ICONS = %w[activity zap message-square settings layers].freeze
    STAT_X0 = 424      # the stats strip, in design coordinates
    STAT_X1 = 1112

    def draw_header
      w = @width
      dx = w - Layout::WIDTH # right-hand header items stay pinned to the right edge
      hh = Layout::HEADER_H
      grad_rect(0, 0, w, hh, col(theme.bg_top, 0.9), col(theme.bg, 0.0))
      @c.glow(0, hh - 5, w, 2, blur: 14, color: col(theme.bolt, 0.35))
      fade_line(0, w, hh - 4, theme.cyan, alpha: 0.95, width: 2, peak: 0.32)
      fade_line(0, w, hh - 1, theme.bolt, alpha: 0.4, width: 1, peak: 0.6)

      # logo: the bot portrait in a round, glowing frame like a profile photo
      @c.glow(29, 12, 62, 62, curve: 31, blur: 10, color: col(theme.cyan, 0.18))
      @c.image_circle("logo", 60, 43, 29)
      @c.circle(60, 43, 30, stroke: col(theme.cyan), strokewidth: 2.5)

      bot = "BOT OPS "
      txt(bot, 112, 19, size: 25, color: theme.text, font: :display, kerning: 1.5)
      txt("BLUE", 112 + text_w(bot, 25, font: :display, kerning: 1.5), 19, size: 25, color: theme.cyan, font: :display, kerning: 1.5)
      txt("AUTOMATE   /   CREATE   /   SCALE", 114, 55, size: 9.5, color: theme.tagline, weight: :medium, kerning: 2.4)

      draw_stats(dx)

      online = @store.online_machines.size
      ok = online.positive? && @store.probe_error.nil?
      status = if @store.probe_error then "PROBE ERROR"
               elsif online.zero? then "WAITING FOR DATA"
               else "#{online} MACHINE#{'S' unless online == 1} ONLINE"
               end
      c = ok ? theme.green : (online.zero? ? theme.yellow : theme.red)
      glow_dot(dx + 1132, 29, col(c), 10)
      txt(status, dx + 1150, 25, size: 12, color: c, weight: :semibold)
      txt(clock_text, dx + 1150, 47, size: 11, color: theme.text)
      fade_vline(dx + 1312, 16, hh - 16, theme.cyan, alpha: 0.45)
      cloud_symbol(dx + 1336, 37, 26, col(theme.cloud), lit: true)
      status = @store.collector_status.to_s
      first, rest = status.start_with?("Collecting on ") ? ["Collecting on", status.delete_prefix("Collecting on ")] : [status, nil]
      txt(fit_text(first, 150, 10.5), dx + 1358, 25, size: 10.5, color: theme.muted)
      txt(fit_text(rest, 150, 10.5), dx + 1358, 42, size: 10.5, color: theme.text) if rest
      draw_window_controls
    end

    # Header stats in a raised strip: icon, label, the number and a note.
    def draw_stats(dx)
      x0 = STAT_X0
      x1 = STAT_X1 + dx
      hh = Layout::HEADER_H
      frame(x0, 10, x1 - x0, hh - 24, curve: 12, glow: 0.18)
      stats = @store.stats
      slot = (x1 - x0 - 16) / stats.size.to_f
      stats.each_with_index do |s, i|
        x = x0 + 14 + slot * i
        tile = 28
        @c.glow(x, 19, tile, tile, curve: 8, blur: 6, color: col(theme.bolt, 0.12))
        grad_rect(x, 19, tile, tile, col(theme.stat_tile_top, 0.9), col(theme.stat_tile_bottom, 0.9), curve: 8)
        icon(STAT_ICONS[i], x + tile / 2.0, 19 + tile / 2.0, 16, col(theme.white))
        tx = x + tile + 9
        avail = slot - tile - 14
        lsize = text_w(s.label, 9.5, :semibold, kerning: 0.3) <= avail ? 9.5 : 8.5
        txt(fit_text(s.label, avail, lsize, :semibold), tx, 18, size: lsize, color: theme.text, weight: :semibold, kerning: 0.3)
        txt(s.value, tx, 33, size: 22, color: theme.white, weight: :bold)
        vw = text_w(s.value, 22, :bold)
        note = fit_text(s.note, avail - vw - 8, 10.5, :medium)
        txt(note, tx + vw + 7, 43, size: 10.5, color: s.note_color, weight: :medium) if vw + 30 < avail
        @c.hit(x - 6, 14, slot - 8, hh - 32) { open_overlay(stat_overlay(i)) }
        fade_vline(x0 + slot * (i + 1) + 4, 20, hh - 24, theme.cyan, alpha: 0.3) if i < stats.size - 1
      end
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

    # [[action, x, y, size], ...]: each icon's box in window coordinates,
    # at the top edge whether windowed or fullscreen.
    def window_controls
      dx = @width - Layout::WIDTH
      CONTROLS.map { |action, x| [action, dx + x, CONTROL_Y, CONTROL_SIZE] }
    end

    def draw_window_controls
      pad = (CONTROL_HIT - CONTROL_SIZE) / 2
      window_controls.each do |action, x, y, s|
        send("icon_#{action}", x, y, s, col(theme.muted))
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
      h = Layout.content_h(@height)
      @c.group(x, Layout::CONTENT_Y) do
        frame(0, 0, w, h, curve: 10)
        Layout::NAV.each_with_index do |(key, name, icon_name), i|
          y = 8 + i * 68
          active = @store.page == key
          if active
            @c.glow(6, y, w - 12, 60, curve: 9, blur: 14, color: col(theme.bolt, 0.55))
            grad_rect(6, y, w - 12, 60, col(theme.nav_active_top), col(theme.nav_active_bottom), curve: 9)
            @c.rect(6, y, w - 12, 60, curve: 9, stroke: col(tint(theme.cyan, 0.3), 0.8))
            fade_line(14, w - 14, y + 0.5, theme.white, alpha: 0.6, peak: 0.5)
          end
          icon(icon_name, w / 2.0, y + 21, 20, col(active ? theme.white : theme.nav_icon, active ? 1 : 0.9))
          txt(name, 0, y + 37, size: 10.5, color: active ? theme.white : theme.nav_text, weight: :medium, width: w, align: :center)
          @c.hit(6, y, w - 12, 60) { show_page(key) }
        end
        # A trace of light up the lower edge, like a circuit lit from below.
        bx = 10
        [[col(theme.cyan, 0.18), 5], [col(theme.cyan, 0.9), 1.6]].each do |c, sw|
          @c.polyline([[bx, h - 14], [bx, h - 60], [w * 0.62, h - 130]], stroke: c, strokewidth: sw, round: true)
        end
        fade_vline(bx, h - 200, h - 14, theme.cyan, alpha: 0.5, peak: 0.85)
      end
    end

    # ---- pages ---------------------------------------------------------

    def place(name, title, geom, opts = {})
      x, y, w, h = geom
      body_h = h - Layout::PANEL_TITLE_H
      opts = opts.merge(title: title, icon: PANEL_ICONS[name])
      opts.delete(:page) if opts[:page] == @store.page
      panel(x - Layout::CONTENT_X, y - Layout::CONTENT_Y, w, h, opts) do
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
        place(:sessions, "CLAUDE SESSIONS", [cx, cy, half, ch], right: sessions_count)
        place(:detail, "SESSION DETAILS", [cx + half + Layout::GAP, cy, half, 300])
        place(:prompts, "RECENT PROMPTS", [cx + half + Layout::GAP, cy + 312, half, ch - 312])
      when :projects
        place(:projects, "PROJECTS · 24H", [cx, cy, cw, ch], right: "#{@store.projects.size} active")
      when :tools
        place(:tools, "TOOL CALLS", [cx, cy, cw, ch])
      when :usage
        place(:usage, "USAGE", [cx, cy, cw - 300 - Layout::GAP, ch])
        place(:machines, "MACHINES", [cx + cw - 300, cy, 300, ch])
      when :logs
        place(:log, "EVENT LOG", [cx, cy, cw, ch], right: "prompts · tools · errors")
      when :machines
        place(:health, "SYSTEM HEALTH", [cx, cy, half, 300], host: health_machine&.dig("host"))
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

    def sessions_count
      "#{@store.sessions.size} live · #{@store.recent_sessions.size} earlier"
    end

    def draw_overview
      place(:sessions, "CLAUDE SESSIONS",  fit(Layout::FLEET), right: sessions_count, page: :sessions)
      place(:live,     "LIVE ACTIVITY",    fit(Layout::ACTIVITY))
      place(:projects, "PROJECTS · 24H",   fit(Layout::WORKFLOWS), right: "#{@store.projects.size} active", page: :projects)
      place(:tools,    "TOOL CALLS",       fit(Layout::QUEUE), page: :tools)
      place(:usage,    "USAGE",            fit(Layout::PIPELINE), page: :usage)
      place(:health,   "SYSTEM HEALTH",    fit(Layout::HEALTH), host: health_machine&.dig("host"))
      place(:prompts,  "RECENT PROMPTS",   fit(Layout::RECENT), page: :sessions)
      place(:detail,   "SESSION DETAILS",  fit(Layout::AGENT))
      place(:log,      "EVENT LOG",        fit(Layout::LOGS), page: :logs)
      place(:machines, "MACHINES",         fit(Layout::REPORTS), right: "#{@store.online_machines.size} online", page: :machines)
    end

    PANEL_ICONS = { sessions: "bot", live: "square-activity", projects: "folder-git-2", tools: "wrench", usage: "chart-line",
                    health: "cpu", prompts: "message-square-text", detail: "info", log: "scroll-text", machines: "server",
                    settings: "settings" }.freeze

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

    # Header stats, left to right: live sessions, busy, prompts, tool calls,
    # output tokens.
    def stat_overlay(index)
      view_overlay([:sessions, :sessions, :prompts, :tools, :tokens][index] || :sessions)
    end

    def set_chart_range(range)
      @store.chart_range = range
      @host.invalidate
    end

    def toggle_series(key)
      @store.toggle_series(key)
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
        @c.line(x + GRIP - 3, y + GRIP - 3 - d, x + GRIP - 3 - d, y + GRIP - 3, stroke: col(theme.muted, 0.7), strokewidth: 1.2)
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
      if @theme_menu
        close_theme_menu
        return true
      end
      return false unless @store.overlay
      close_overlay
      true
    end

    KEY_ESC, KEY_UP, KEY_DOWN, KEY_ENTER, KEY_BACKSPACE = 27, 38, 40, 13, 8

    # Keys, in this order of who gets them: the search box, an open overlay
    # (arrows scroll it), then the sessions list (Up/Down select, Enter opens
    # the timeline). True when something used the key.
    def key(code)
      o = @store.overlay
      return escape if code == KEY_ESC
      if o&.search?
        results = @store.search(o.query)
        case code
        when KEY_BACKSPACE then o.query = o.query[0...-1]; o.selected = 0
        when KEY_UP then o.selected = [o.selected - 1, 0].max
        when KEY_DOWN then o.selected = [o.selected + 1, [results.size - 1, 0].max].min
        when KEY_ENTER then results[o.selected] ? open_overlay(event_overlay(results[o.selected])) : nil
        else return false
        end
      elsif o
        case code
        when KEY_UP then o.scroll_by(-1)
        when KEY_DOWN then o.scroll_by(1)
        else return false
        end
      else
        case code
        when KEY_UP, KEY_DOWN then move_selection(code == KEY_UP ? -1 : 1)
        when KEY_ENTER then (s = @store.selected_session) ? open_overlay(timeline_overlay(s)) : nil
        else return false
        end
      end
      @host.invalidate
      true
    end

    # Typed text: the query while searching; "/" opens the search box.
    def text(str)
      o = @store.overlay
      if o&.search?
        clean = str.gsub(/[[:cntrl:]]/, "")
        return false if clean.empty?
        o.query << clean
        o.selected = 0
      elsif o.nil? && str.include?("/")
        open_overlay(SearchOverlay.new)
      else
        return false
      end
      @host.invalidate
      true
    end

    def move_selection(by)
      list = @store.all_sessions
      return if list.empty?
      i = list.index { |s| s["id"] == @store.selected_session&.dig("id") } || 0
      @store.selected_session_id = list[(i + by).clamp(0, list.size - 1)]["id"]
    end

    def toggle_session_only
      @store.session_only = !@store.session_only
      @host.invalidate
    end

    OVERLAY_TEXT = 10
    OVERLAY_LINE = 16

    def mono_char
      @mono_char || OVERLAY_TEXT * 0.602 # DejaVu Sans Mono's nominal advance
    end

    # The box: centred, dimmed backdrop, electric frame, title, close X, and a
    # scrolling window of the content's lines with a scrollbar when it
    # overflows. A click on the backdrop closes it; clicks inside don't.
    def draw_overlay(o)
      w, h = @width, @height
      @c.rect(0, 0, w, h, fill: col(theme.bg, 0.78))
      @c.hit(0, 0, w, h) { close_overlay }

      bw = [[w - 260, 1040].min, 560].max
      bh = [[h - 200, 780].min, 320].max
      bx = (w - bw) / 2
      by = (h - bh) / 2
      # Glow first, then the box's own dark fill over it, then the outline:
      # a glow drawn after the fill would tint the whole box blue.
      @c.glow(bx, by, bw, bh, curve: 10, blur: 22, color: col(theme.border, 0.35))
      @c.rect(bx, by, bw, bh, curve: 10, fill: col(theme.overlay_bg))
      frame(bx, by, bw, bh, curve: 10, glow: 0, fill: false)
      @c.hit(bx, by, bw, bh) {}

      tabs_w = 0
      if (t = o.tabs)
        tabs_w = t[:labels].size * 52
        t[:labels].each_with_index do |label, i|
          tab(bx + bw - 56 - tabs_w + i * 52, by + 16, label, label == t[:active], width: 46) { open_overlay(t[:select].call(label)) }
        end
      end
      @c.clip(bx + 16, by + 8, bw - 72 - tabs_w, 44) do
        txt(clip(o.title, (bw - 90) / 8), bx + 22, by + 14, size: 13, color: theme.text, weight: :bold)
        txt(clip(o.subtitle, (bw - 60) / 5.5), bx + 22, by + 36, size: 9, color: theme.muted) if o.subtitle
      end
      cx = bx + bw - 34
      @c.line(cx, by + 16, cx + 12, by + 28, stroke: col(theme.muted), strokewidth: 1.5)
      @c.line(cx + 12, by + 16, cx, by + 28, stroke: col(theme.muted), strokewidth: 1.5)
      @c.hit(cx - 6, by + 10, 24, 24) { close_overlay }
      fade_line(bx + 14, bx + bw - 14, by + 56, theme.bolt)

      return draw_search(o, bx, by, bw, bh) if o.search?

      top = by + 68
      body_h = bh - 68 - 30
      visible = body_h / OVERLAY_LINE
      view_w = bw - 48 # the body's text width inside the clip
      lines = o.lines((view_w / mono_char).floor)
      o.offset = o.offset.clamp(0, [lines.size - visible, 0].max)
      content_w = lines.map { |l| Overlay.columns(l) }.max.to_i * mono_char
      max_x = [content_w - view_w, 0].max
      o.x_offset = o.x_offset.clamp(0, max_x)
      left = bx + 24 - o.x_offset

      # Lines are drawn as written (never wrapped) and clipped to the body;
      # the body pans sideways (drag it, or swipe sideways) to show the rest.
      @c.clip(bx + 16, top - 2, bw - 38, body_h + 4) do
        lines[o.offset, visible].to_a.each_with_index do |(style, a, b, label_w), i|
          y = top + i * OVERLAY_LINE
          case style
          when :field
            txt(a, left, y, size: OVERLAY_TEXT, color: theme.muted, mono: true)
            txt(b, left + label_w * mono_char, y, size: OVERLAY_TEXT, color: theme.text, mono: true)
          when :heading then txt(a, left, y, size: OVERLAY_TEXT, color: theme.cyan, weight: :bold)
          when :note then txt(a, bx + 24, y, size: OVERLAY_TEXT, color: theme.dim, mono: true)
          when :blank then nil
          else txt(a, left, y, size: OVERLAY_TEXT, color: theme.text, mono: true)
          end
        end
      end

      if lines.size > visible
        track_h = body_h - 4
        thumb_h = [track_h * visible / lines.size, 24].max
        thumb_y = top + (track_h - thumb_h) * o.offset / (lines.size - visible).to_f
        @c.rect(bx + bw - 16, top, 4, track_h, curve: 2, fill: col(theme.track))
        @c.rect(bx + bw - 16, thumb_y, 4, thumb_h, curve: 2, fill: col(theme.bolt, 0.9))
      end
      if max_x.positive?
        track_w = bw - 64
        thumb_w = [track_w * view_w / content_w, 24].max
        thumb_x = bx + 24 + (track_w - thumb_w) * o.x_offset / max_x
        @c.rect(bx + 24, top + body_h + 4, track_w, 4, curve: 2, fill: col(theme.track))
        @c.rect(thumb_x, top + body_h + 4, thumb_w, 4, curve: 2, fill: col(theme.bolt, 0.9))
      end
      hints = []
      hints << "Scroll for more" if lines.size > visible
      hints << "drag or swipe sideways for long lines" if max_x.positive?
      hints << "Esc, X or a click outside closes"
      txt(hints.join("  ·  "), bx + 24, by + bh - 18, size: 8, color: theme.dim)
    end

    # The search box and its results, inside the overlay frame.
    def draw_search(o, bx, by, bw, bh)
      top = by + 68
      @c.rect(bx + 20, top - 4, bw - 40, 28, curve: 6, fill: col(theme.panel2), stroke: col(theme.bolt, 0.8))
      cursor = (Time.now.to_f * 2).to_i.even? ? "▏" : " "
      @c.clip(bx + 24, top - 4, bw - 48, 28) do
        txt(o.query.empty? ? "Type to search…" : o.query + cursor, bx + 32, top + 2, size: 11,
            color: o.query.empty? ? theme.dim : theme.text, mono: true)
      end
      results = @store.search(o.query)
      o.selected = o.selected.clamp(0, [results.size - 1, 0].max)
      list_top = top + 36
      rows = (bh - (list_top - by) - 30) / OVERLAY_LINE
      first = [o.selected - rows + 1, 0].max
      @c.clip(bx + 16, list_top - 2, bw - 32, rows * OVERLAY_LINE + 4) do
        results[first, rows].to_a.each_with_index do |e, i|
          y = list_top + i * OVERLAY_LINE
          if first + i == o.selected
            @c.rect(bx + 18, y - 2, bw - 36, OVERLAY_LINE, curve: 3, fill: col(theme.bolt, 0.18))
          end
          kind = e["kind"] == "tool" ? e["title"] : e["kind"]
          line = "#{Time.at(e['at'].to_f).strftime('%H:%M')}  #{kind.to_s.ljust(10)[0, 10]}  #{e['session'].to_s[0, 28].ljust(28)}  #{e['detail']}"
          txt(line, bx + 24, y, size: OVERLAY_TEXT, color: e["kind"] == "error" ? theme.red : theme.text, mono: true)
          @c.hit(bx + 18, y - 2, bw - 36, OVERLAY_LINE) { open_overlay(event_overlay(e)) }
        end
      end
      status = if o.query.strip.empty? then "Search words must all appear (case-insensitive)."
               elsif results.empty? then "No matches."
               else "#{results.size}#{results.size == 200 ? '+' : ''} matches  ·  Up/Down to choose, Enter or click to open"
               end
      txt("#{status}  ·  Esc closes", bx + 24, by + bh - 18, size: 8, color: theme.dim)
    end

    # The overlay's body, where a drag pans the text ([x, y, w, h]), or nil.
    def pan_region
      return nil if @store.overlay.nil? || @store.overlay.search?
      w, h = @width, @height
      bw = [[w - 260, 1040].min, 560].max
      bh = [[h - 200, 780].min, 320].max
      bx = (w - bw) / 2
      by = (h - bh) / 2
      [bx + 16, by + 66, bw - 38, bh - 68 - 30 + 4]
    end

    # Drag or sideways swipe, in points: moves the text with the pointer.
    def pan(dx, dy)
      o = @store.overlay
      return false unless o && (dx != 0 || dy != 0)
      o.pan_by(dx)
      @pan_dy = (@pan_dy || 0) + dy
      lines = (@pan_dy / OVERLAY_LINE.to_f).truncate
      if lines != 0
        o.scroll_by(lines)
        @pan_dy -= lines * OVERLAY_LINE
      end
      @host.invalidate
      true
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
