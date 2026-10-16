# frozen_string_literal: true

module BotOps
  # Drawing helpers on top of Canvas. Mixed into Scene, which provides @c
  # (the canvas being built), @store and @host.
  #
  # The look: deep navy panels lit from above (a vertical gradient), a fine
  # electric-blue outline with a soft outer glow, and highlights along the
  # edges that are brightest in one place and fade to nothing toward the
  # corners. Icons are Lucide line icons (ICONS) on gradient discs and tiles.
  module Widgets
    include Theme

    # ---- colours -------------------------------------------------------

    def col(hex, alpha = 1.0)
      r, g, b = Theme.hex_rgb(hex)
      [r, g, b, alpha.to_f]
    end

    # `hex` moved toward `other` by t (0..1), as a hex string.
    def mix(hex, other, t)
      a = Theme.hex_rgb(hex)
      b = Theme.hex_rgb(other)
      format("#%02X%02X%02X", *a.zip(b).map { |x, y| (x + (y - x) * t).round })
    end

    def tint(hex, t)
      mix(hex, "#FFFFFF", t)
    end

    def shade(hex, t)
      mix(hex, "#000000", t)
    end

    # ---- text ----------------------------------------------------------

    def txt(str, x, y, opts = {})
      @c.text(str, x, y,
              size: opts[:size] || 11,
              color: col(opts[:color] || theme.text, opts[:alpha] || 1.0),
              weight: opts[:weight] ? opts[:weight].to_sym : :normal,
              family: opts[:mono] ? :mono : (opts[:font] || :sans),
              width: opts[:width],
              align: (opts[:align] || :left).to_sym,
              kerning: opts[:kerning] || 0)
    end

    def label(str, x, y, opts = {})
      txt(str, x, y, { size: 9, color: theme.muted }.merge(opts))
    end

    # Width of `str` in points as the native side lays it out.
    def text_w(str, size, weight = :normal, font: nil, kerning: 0)
      table = FONT_METRICS[font == :display ? :display : (font == :mono ? :mono : weight)] || FONT_METRICS[:normal]
      str.to_s.each_char.sum { |ch| (table[ch] || 0.62) * size + kerning }
    end

    # Truncate text that would otherwise run into the next column.
    def clip(str, max_chars)
      s = str.to_s
      s.length > max_chars ? "#{s[0, [max_chars - 1, 1].max]}…" : s
    end

    # Truncate to `max_w` points, ending in "…".
    def fit_text(str, max_w, size, weight = :normal, font: nil)
      s = str.to_s
      return s if text_w(s, size, weight, font: font) <= max_w
      ell = text_w("…", size, weight, font: font)
      out = +""
      used = 0.0
      s.each_char do |ch|
        cw = text_w(ch, size, weight, font: font)
        break if used + cw + ell > max_w
        out << ch
        used += cw
      end
      "#{out.rstrip}…"
    end

    # ---- lines ---------------------------------------------------------

    # A horizontal line that fades in from x1, peaks at `peak` (a fraction of
    # the way along) and fades out by x2.
    def fade_line(x1, x2, y, hex, alpha: 0.55, width: 1, peak: 0.35)
      xp = x1 + (x2 - x1) * peak
      clear = col(hex, 0)
      bright = col(hex, alpha)
      h = width / 2.0
      @c.gradient([[x1, y - h], [xp, y - h], [xp, y + h], [x1, y + h]], x1, y, xp, y, from: clear, to: bright) if xp > x1
      @c.gradient([[xp, y - h], [x2, y - h], [x2, y + h], [xp, y + h]], xp, y, x2, y, from: bright, to: clear) if x2 > xp
    end

    def fade_vline(x, y1, y2, hex, alpha: 0.4, width: 1, peak: 0.5)
      yp = y1 + (y2 - y1) * peak
      clear = col(hex, 0)
      bright = col(hex, alpha)
      h = width / 2.0
      @c.gradient([[x - h, y1], [x + h, y1], [x + h, yp], [x - h, yp]], x, y1, x, yp, from: clear, to: bright) if yp > y1
      @c.gradient([[x - h, yp], [x + h, yp], [x + h, y2], [x - h, y2]], x, yp, x, y2, from: bright, to: clear) if y2 > yp
    end

    def hline(x1, x2, y, color = col(theme.cyan, 0.12), width = 1)
      @c.line(x1, y, x2, y, stroke: color, strokewidth: width)
    end

    def vline(x, y1, y2, color = col(theme.cyan, 0.12), width = 1)
      @c.line(x, y1, x, y2, stroke: color, strokewidth: width)
    end

    # ---- fills ---------------------------------------------------------

    # A rounded rectangle filled top-to-bottom (or left-to-right) from one
    # colour to another.
    def grad_rect(x, y, w, h, from, to, curve: 0, across: false)
      pts = Canvas.rounded_rect(x, y, w, h, curve)
      if across
        @c.gradient(pts, x, y, x + w, y, from: from, to: to)
      else
        @c.gradient(pts, x, y, x, y + h, from: from, to: to)
      end
    end

    def grad_circle(cx, cy, r, from, to)
      @c.gradient(Canvas.circle_points(cx, cy, r), cx - r * 0.7, cy - r * 0.7, cx + r * 0.7, cy + r * 0.7, from: from, to: to)
    end

    # ---- boxes ---------------------------------------------------------

    # The panel look: soft glow, lit-from-above fill, fine outline, and
    # highlights along the top and left edges.
    def frame(x, y, w, h, curve: 10, glow: 0.26, accent: theme.border, fill: true)
      @c.glow(x, y, w, h, curve: curve, blur: 18, color: col(accent, glow)) if glow.positive?
      grad_rect(x, y, w, h, col(theme.panel_top, 0.97), col(theme.panel, 0.97), curve: curve) if fill
      @c.rect(x, y, w, h, curve: curve, stroke: col(accent, 0.72), strokewidth: 1.2)
      fade_line(x + curve, x + w - curve, y + 0.5, theme.cyan, alpha: 0.9, width: 1.2, peak: 0.3)
      fade_line(x + curve, x + w - curve, y + h - 0.5, theme.bolt, alpha: 0.45, width: 1, peak: 0.6)
      fade_vline(x + 0.5, y + curve, y + h - curve, theme.cyan, alpha: 0.35, peak: 0.25)
    end

    def box(x, y, w, h, opts = {})
      curve = opts[:curve] || 8
      if opts[:fill].is_a?(Array) && opts[:flat]
        @c.rect(x, y, w, h, curve: curve, fill: opts[:fill])
      else
        grad_rect(x, y, w, h, col(theme.card_top, 0.75), col(theme.panel2, 0.75), curve: curve)
      end
      @c.rect(x, y, w, h, curve: curve, stroke: opts[:stroke] || col(theme.border, 0.32), strokewidth: opts[:strokewidth] || 1)
    end

    # A row card. `accent`: a colour for the outline (and a glow when
    # selected).
    def card(x, y, w, h, accent: nil, selected: false, curve: 9)
      c = accent || theme.border
      @c.glow(x, y, w, h, curve: curve, blur: 10, color: col(selected ? theme.cyan : c, selected ? 0.35 : 0.10))
      grad_rect(x, y, w, h, col(theme.card_top, 0.85), col(theme.panel2, 0.85), curve: curve)
      @c.rect(x, y, w, h, curve: curve, stroke: col(selected ? theme.cyan : c, selected ? 0.85 : (accent ? 0.5 : 0.30)))
      fade_line(x + curve, x + w - curve, y + 0.5, selected ? theme.cyan : c, alpha: selected ? 0.7 : 0.35, peak: 0.25)
    end

    # Filled circle whose top-left corner is (x, y) and diameter d.
    def dot(x, y, color, d = 6)
      @c.circle(x + d / 2.0, y + d / 2.0, d / 2.0, fill: color)
    end

    # A dot with a soft halo. Rings, not a blurred shadow: egui's shadow
    # turns spiky when the shape is smaller than its blur.
    def glow_dot(x, y, color, d = 6)
      cx = x + d / 2.0
      cy = y + d / 2.0
      [[d / 2.0 + 2.5, 0.07], [d / 2.0 + 1.2, 0.14]].each do |r, a|
        @c.circle(cx, cy, r, fill: [color[0], color[1], color[2], a])
      end
      dot(x, y, color, d)
    end

    # A framed dashboard panel. The block draws the body with its origin at
    # the panel's top-left corner just below the title bar.
    #   icon: an ICONS name before the title; right: a count shown in a pill;
    #   page: the page its chevron opens.
    def panel(x, y, w, h, opts = {})
      frame(x, y, w, h)
      if opts[:title]
        tx = x + 18
        if opts[:icon]
          icon(opts[:icon], tx + 8, y + 19, 17, col(theme.cyan))
          tx += 26
        end
        txt(opts[:title], tx, y + 12, size: 12.5, color: theme.text, weight: :semibold, kerning: 0.6)
        if opts[:host]
          hx = tx + text_w(opts[:title], 12.5, :semibold, kerning: 0.6)
          txt(fit_text("· #{opts[:host]}", x + w - hx - 28, 12, :medium), hx + 8, y + 12.5, size: 12, color: theme.text, weight: :medium)
        end
        fade_line(x + 12, x + w - 12, y + Layout::PANEL_TITLE_H, theme.border, alpha: 0.55, peak: 0.3)
      end
      rx = x + w - 14
      if opts[:page]
        icon("chevron-right", rx - 6, y + 19, 14, col(theme.cyan, 0.8))
        @c.hit(rx - 16, y + 6, 22, 26) { show_page(opts[:page]) }
        rx -= 20
      end
      if opts[:right]
        pill_w = text_w(opts[:right], 11, :medium) + 32
        px = rx - pill_w
        c = opts[:right_color] || theme.cyan
        @c.rect(px, y + 7, pill_w, 24, curve: 12, fill: col(c, 0.07), stroke: col(c, 0.45))
        txt(opts[:right], px + 12, y + 11.5, size: 11, color: c, weight: :medium)
        icon("chevron-right", px + pill_w - 13, y + 19, 11, col(c, 0.9))
      end
      @c.group(x, y + Layout::PANEL_TITLE_H) { yield } if block_given?
    end

    # ---- indicators ----------------------------------------------------

    def status_pill(x, y, status, opts = {})
      c = Theme.status_color(status)
      d = 7
      (status == "Busy" || status == "Needs you") ? glow_dot(x, y + 4, col(c), d) : dot(x, y + 4, col(c), d)
      txt(status, x + 13, y, size: opts[:size] || 10.5, color: c == theme.slate ? theme.muted : c, weight: :medium)
    end

    def priority_pill(x, y, priority)
      c = Theme.priority_color(priority)
      dot(x, y + 4, col(c), 6)
      txt(priority, x + 10, y - 1, size: 9, color: c)
    end

    def hbar(x, y, w, h, pct, color_hex, opts = {})
      pct = [[pct.to_f, 0].max, 100].min
      @c.rect(x, y, w, h, curve: h / 2.0, fill: col(theme.track, 0.8))
      fw = (w * pct / 100.0).round
      return unless fw > 0
      @c.glow(x, y, [fw, h].max, h, curve: h / 2.0, blur: 6, color: col(color_hex, 0.5)) unless opts[:no_glow]
      grad_rect(x, y, [fw, h].max, h, col(shade(color_hex, 0.2)), col(tint(color_hex, 0.2)), curve: h / 2.0, across: true)
    end

    # Points along a circle from start_deg sweeping sweep_deg (0 = 3 o'clock,
    # clockwise), close enough together that a thick stroke stays round.
    def arc_points(cx, cy, r, start_deg, sweep_deg)
      n = [(sweep_deg.abs / 3.0).ceil, 2].max
      (0..n).map { |i| a = (start_deg + sweep_deg * i / n.to_f) * Math::PI / 180; [cx + r * Math.cos(a), cy + r * Math.sin(a)] }
    end

    # Ring gauge, drawn as a neon tube: a dark grooved track, an arc from
    # 12 o'clock clockwise with round ends, a bloom around it and a lighter
    # core along it. In the middle the percentage (its unit smaller) over an
    # icon; beneath the ring, the label in small capitals.
    def donut(cx, cy, r, pct, color_hex, opts = {})
      thickness = opts[:thickness] || [(r * 0.14).round, 4].max
      pct = [[pct.to_f, 0].max, 100].min
      rr = r - thickness / 2.0
      @c.circle(cx, cy, rr, stroke: col(theme.track, 0.95), strokewidth: thickness)
      @c.circle(cx, cy, r, stroke: col(theme.border, 0.28), strokewidth: 1)
      @c.circle(cx, cy, r - thickness, stroke: col(theme.border, 0.22), strokewidth: 1)
      if pct > 0.5
        sweep = 360.0 * pct / 100.0
        # The bloom: faint passes widening outside the tube, each reaching a
        # little past its ends so their blunt ends hide behind the round
        # ones (round caps on every pass would stack into bright blobs).
        1.upto(2) do |i|
          sw = thickness + i * 2
          ext = i * 180 / (Math::PI * rr)
          @c.polyline(arc_points(cx, cy, rr, -90 - ext, sweep + 2 * ext), stroke: col(color_hex, 0.03), strokewidth: sw)
        end
        pts = arc_points(cx, cy, rr, -90, sweep)
        @c.polyline(pts, stroke: col(color_hex), strokewidth: thickness, round: true)
        @c.polyline(pts, stroke: col(tint(color_hex, 0.55), 0.45), strokewidth: thickness * 0.25, round: true)
      end
      num = pct.round.to_s
      ns = opts[:size] || (r * 0.56).round
      us = (ns * 0.55).round
      nw = text_w(num, ns, :bold)
      x0 = cx - (nw + text_w("%", us, :semibold)) / 2.0
      # Capitals sit 0.24em below the top of the text box and are 0.73em
      # tall, so this centres the digits a little above the ring's centre.
      ty = cy - (opts[:icon] ? r * 0.08 : 0) - ns * 0.6
      txt(num, x0, ty, size: ns, color: theme.text, weight: :bold)
      txt("%", x0 + nw, ty + (ns - us) * 0.93, size: us, color: theme.text, weight: :semibold)
      icon(opts[:icon], cx, cy + r * 0.47, r * 0.34, col(color_hex, 0.9)) if opts[:icon]
      return unless opts[:label]
      txt(opts[:label].to_s.upcase, cx - r - 12, cy + r + 10, size: 10.5, color: mix(theme.cyan, theme.text, 0.35), weight: :semibold,
                                    width: r * 2 + 24, align: :center, kerning: 1.6)
    end

    # ---- icons ---------------------------------------------------------

    # A line icon from ICONS (Lucide's 24-unit box), `size` wide, centred
    # on (cx, cy). Brand marks are outlines, so they get a finer line.
    def icon(name, cx, cy, size, color, width: nil)
      return cloud_symbol(cx, cy, size, color) if name.to_s == "cloud" && width.nil?
      lines = ICONS[name.to_s] or return
      k = size / 24.0
      sw = width || [(name.to_s == "vscode" ? 1.25 : 2.0) * k, 1.0].max
      ox = cx - size / 2.0
      oy = cy - size / 2.0
      lines.each do |closed, flat|
        pts = flat.each_slice(2).map { |px, py| [ox + px * k, oy + py * k] }
        @c.polyline(pts, stroke: color, strokewidth: sw, closed: closed, round: true)
      end
    end

    # The cloud, as the designer drew it, `size` wide and centred on
    # (cx, cy). On a disc or tile it's a clean outline; standing alone
    # (lit: true) it glows, with a dark inside and a stroke that's lighter
    # along the top, as if lit from above.
    def cloud_symbol(cx, cy, size, color, lit: false)
      k = size / 24.0
      all = ICONS["cloud"][0][1].each_slice(2).to_a
      # Small clouds use fewer points (about one per 1.5pt of outline):
      # thick strokes along many tiny segments fray.
      step = [(all.size * 1.5 / (size * 2.6)).floor, 1].max
      pts = all.each_slice(step).map(&:first).map { |px, py| [cx + (px - 12) * k, cy + (py - 12) * k] }
      # The drawing's line is about 1/27 of the cloud's width; small clouds
      # keep at least a pixel and a half so they stay crisp.
      sw = [0.75 * k, lit ? 1.5 : 1.35].max
      unless lit
        @c.polyline(pts, stroke: color, strokewidth: sw, closed: true, round: true)
        return
      end
      hex = format("#%02X%02X%02X", *color[0, 3])
      center = [cx + (CLOUD_ORIGIN[0] - 12) * k, cy + (CLOUD_ORIGIN[1] - 12) * k]
      top = pts.map(&:last).min
      bottom = pts.map(&:last).max
      @c.polyline(pts, stroke: col(hex, 0.08), strokewidth: sw * 3 + 3, closed: true)
      @c.polyline(pts, stroke: col(hex, 0.16), strokewidth: sw * 2 + 1, closed: true)
      @c.gradient(pts, cx, top, cx, bottom, from: col(shade(hex, 0.6), 0.95), to: col(shade(hex, 0.82), 0.95), center: center)
      @c.polyline(pts, stroke: col(hex), strokewidth: sw, closed: true, round: true)
      # The top catches the light: three overlapping passes, each reaching
      # less far down, so the highlight fades out instead of stopping.
      [0.55, 0.42, 0.3].each do |reach|
        cut = top + (bottom - top) * reach
        idx = pts.each_index.select { |i| pts[i][1] < cut }
        idx.slice_when { |a, b| b != a + 1 }.each do |run|
          next if run.size < 2
          @c.polyline(run.map { |i| pts[i] }, stroke: col(tint(hex, 0.6), 0.33), strokewidth: sw * 0.7)
        end
      end
    end

    # What goes on a disc or tile: an ICONS name, :cloud, or a letter.
    def icon_glyph(glyph, x, y, d, color)
      name = glyph == :cloud ? "cloud" : glyph.to_s
      if name == "cloud"
        cloud_symbol(x + d / 2.0, y + d / 2.0, d * 0.56, color)
      elsif ICONS.key?(name)
        icon(name, x + d / 2.0, y + d / 2.0, d * 0.5, color)
      else
        size = d * 0.46
        txt(glyph, x, y + d / 2.0 - size * 0.6, size: size, color: color.is_a?(Array) ? theme.white : color,
                                                 weight: :semibold, width: d, align: :center)
      end
    end

    # A glowing gradient disc with a white icon: light from the top left,
    # deeper toward the bottom right.
    def avatar(x, y, color_hex, glyph, d = 30, dim: false)
      cx = x + d / 2.0
      cy = y + d / 2.0
      base = dim ? mix(color_hex, theme.slate, 0.6) : color_hex
      @c.glow(x, y, d, d, curve: d / 2.0, blur: d * 0.18, color: col(base, dim ? 0.05 : 0.12))
      grad_circle(cx, cy, d / 2.0, col(tint(base, 0.18)), col(shade(base, 0.38)))
      @c.circle(cx, cy, d / 2.0 - 0.5, stroke: col(tint(base, 0.45), 0.45), strokewidth: 1)
      icon_glyph(glyph, x, y, d, col(theme.white, dim ? 0.7 : 0.97))
    end

    # The same as a rounded tile.
    def square_icon(x, y, color_hex, glyph, d = 28)
      curve = d * 0.24
      @c.glow(x, y, d, d, curve: curve, blur: d * 0.18, color: col(color_hex, 0.12))
      @c.gradient(Canvas.rounded_rect(x, y, d, d, curve), x, y, x + d, y + d,
                  from: col(tint(color_hex, 0.18)), to: col(shade(color_hex, 0.38)))
      @c.rect(x, y, d, d, curve: curve, stroke: col(tint(color_hex, 0.45), 0.4))
      icon_glyph(glyph, x, y, d, col(theme.white, 0.97))
    end

    # Pill-shaped tab; returns its width. The block runs when it is clicked.
    def tab(x, y, text, active, opts = {}, &on_click)
      h = opts[:height] || 24
      w = opts[:width] || (text_w(text, 11, :medium) + 30).round
      if active
        @c.glow(x, y, w, h, curve: h / 2.0, blur: 10, color: col(theme.bolt, 0.45))
        grad_rect(x, y, w, h, col(theme.pill_top), col(theme.pill_bottom), curve: h / 2.0)
        @c.rect(x, y, w, h, curve: h / 2.0, stroke: col(tint(theme.cyan, 0.3), 0.75))
      else
        @c.rect(x, y, w, h, curve: h / 2.0, fill: col(theme.panel2, 0.8), stroke: col(theme.border, 0.55))
      end
      txt(text, x, y + (h - 11) / 2.0 - 1, size: 11, color: active ? theme.white : theme.text, weight: :medium, width: w, align: :center)
      @c.hit(x, y, w, h, &on_click) if on_click
      w
    end

    # Text that acts as a button.
    def link(text, x, y, opts = {}, &on_click)
      size = opts[:size] || 9
      txt(text, x, y, { size: size, color: theme.cyan }.merge(opts))
      w = opts[:width] || text_w(text, size, opts[:weight] || :normal)
      @c.hit(x - 2, y - 2, w + 4, size + 8, &on_click)
    end

    def chevron(cx, cy, color = col(theme.muted, 0.8), size = 13)
      icon("chevron-right", cx, cy, size, color)
    end

    # ---- charts --------------------------------------------------------

    def line_chart(x, y, w, h, labels, series, opts = {})
      max = opts[:max] || 60
      steps = opts[:steps] || 6
      pad_l = 30
      pad_b = 20
      gx = x + pad_l
      gy = y
      gw = w - pad_l
      gh = h - pad_b

      steps.downto(0) do |i|
        yy = gy + gh - (gh * i / steps.to_f)
        hline(gx, gx + gw, yy, col(theme.border, i.zero? ? 0.35 : 0.16))
        label((max * i / steps).round, x - 4, yy - 7, size: 10, color: theme.muted, width: pad_l - 4, align: :right)
      end

      n = labels.size
      return if n < 2
      xs = (0...n).map { |i| gx + (gw * i / (n - 1).to_f) }
      labels.each_with_index do |lab, i|
        vline(xs[i], gy, gy + gh, col(theme.border, 0.10))
        label(lab, xs[i] - 26, gy + gh + 6, size: 10, color: theme.muted, width: 52, align: :center)
      end

      series.each do |s|
        pts = s[:values].each_with_index.map { |v, i| [xs[i], gy + gh - (gh * [[v, 0].max, max].min / max.to_f)] }
        next if pts.size < 2
        c = col(s[:color])
        @c.area(pts, gy + gh, fill: col(s[:color], 0.38), fade: col(s[:color], 0.0), top_y: gy)
        @c.polyline(pts, stroke: col(s[:color], 0.16), strokewidth: 5, round: true)
        @c.polyline(pts, stroke: c, strokewidth: 2, round: true)
        dense = pts.size > 16
        pts.each do |px, py|
          next if py >= gy + gh - 0.5 # points on the floor would only add noise
          @c.circle(px, py, dense ? 3 : 4, fill: col(s[:color], 0.12))
          @c.circle(px, py, dense ? 2 : 2.8, fill: col(tint(s[:color], 0.3)))
        end
      end
    end

    def legend(x, y, series, gap = 22)
      series.each_with_index do |s, i|
        glow_dot(x, y + i * gap + 3, col(s[:color]), 7)
        txt(s[:name], x + 16, y + i * gap - 1, size: 11, color: theme.text)
      end
    end
  end
end
