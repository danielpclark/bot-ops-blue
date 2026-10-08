# frozen_string_literal: true

module BotOps
  # Low-level drawing helpers. These are mixed into the running Shoes::App
  # (via `extend`), so every method here can call the Shoes DSL directly
  # (stack, para, rect, oval, line, arc ...). Coordinates are relative to the
  # slot currently being drawn into.
  module Widgets
    include Theme

    TAU = Math::PI * 2

    # ---- colours -------------------------------------------------------

    def col(hex, alpha = nil)
      return hex if alpha.nil?
      r, g, b = Theme.hex_rgb(hex)
      rgb(r, g, b, alpha.to_f)
    end

    # ---- text ----------------------------------------------------------

    def txt(str, x, y, opts = {})
      style = {
        left: x, top: y,
        size: opts[:size] || 11,
        stroke: opts[:color] || TEXT,
        family: opts[:mono] ? MONO : FAMILY
      }
      style[:weight]  = opts[:weight] if opts[:weight]
      style[:width]   = opts[:width]  if opts[:width]
      style[:align]   = opts[:align]  if opts[:align]
      style[:kerning] = opts[:kerning] if opts[:kerning]
      para(str.to_s, style)
    end

    def label(str, x, y, opts = {})
      txt(str, x, y, { size: 9, color: MUTED }.merge(opts))
    end

    # ---- boxes ---------------------------------------------------------

    def box(x, y, w, h, opts = {})
      rect(left: x, top: y, width: w, height: h,
           curve: opts[:curve] || 6,
           fill: opts[:fill] || col(PANEL2),
           stroke: opts[:stroke] || col(CYAN, 0.18),
           strokewidth: opts[:strokewidth] || 1)
    end

    def hline(x1, x2, y, color = col(CYAN, 0.12), width = 1)
      line(x1, y, x2, y, stroke: color, strokewidth: width)
    end

    def vline(x, y1, y2, color = col(CYAN, 0.12), width = 1)
      line(x, y1, x, y2, stroke: color, strokewidth: width)
    end

    def dot(x, y, color, d = 6)
      oval(left: x, top: y, width: d, height: d, fill: color, stroke: color)
    end

    def glow_dot(x, y, color, d = 6)
      oval(left: x - 3, top: y - 3, width: d + 6, height: d + 6, fill: col(color, 0.18), stroke: col(color, 0.0))
      dot(x, y, color, d)
    end

    # A framed dashboard panel. Returns the body slot (below the title bar) so
    # callers can `body.clear { ... }` on refresh without redrawing the frame.
    def panel(x, y, w, h, opts = {}, &body)
      stack(left: x, top: y, width: w, height: h) do
        background col(PANEL), curve: 7
        border col(CYAN, 0.3), strokewidth: 1, curve: 7
        # top edge highlight
        line(14, 1, w - 14, 1, stroke: col(CYAN, 0.35), strokewidth: 1)
        if opts[:title]
          txt(opts[:title], 16, 11, size: 11, color: TEXT, weight: "bold", kerning: 1)
        end
        if opts[:right]
          txt(opts[:right], w - 16 - (opts[:right_w] || 120), 11,
              size: 10, color: opts[:right_color] || CYAN, width: opts[:right_w] || 120, align: "right")
        end
        hline(1, w - 1, Layout::PANEL_TITLE_H - 1, col(CYAN, 0.1)) if opts[:title] && !opts[:no_rule]
      end
      stack(left: x, top: y + Layout::PANEL_TITLE_H, width: w, height: h - Layout::PANEL_TITLE_H, &body)
    end

    # ---- indicators ----------------------------------------------------

    def status_pill(x, y, status, opts = {})
      c = Theme.status_color(status)
      dot(x, y + 4, c, 6)
      txt(status, x + 10, y - 1, size: opts[:size] || 9, color: c)
    end

    def priority_pill(x, y, priority)
      c = Theme.priority_color(priority)
      dot(x, y + 4, c, 6)
      txt(priority, x + 10, y - 1, size: 9, color: c)
    end

    def hbar(x, y, w, h, pct, color, opts = {})
      pct = [[pct.to_f, 0].max, 100].min
      rect(left: x, top: y, width: w, height: h, curve: h / 2, fill: col(TRACK), stroke: col(TRACK))
      fw = (w * pct / 100.0).round
      if fw > 0
        rect(left: x, top: y, width: [fw, h].max, height: h, curve: h / 2, fill: color, stroke: color)
        unless opts[:no_glow]
          rect(left: x, top: y - 1, width: [fw, h].max, height: h + 2, curve: h / 2,
               fill: col(color, 0.0), stroke: col(color, 0.25))
        end
      end
    end

    # Circular gauge: a track ring, a coloured arc, and the percentage inside.
    def donut(cx, cy, r, pct, color, opts = {})
      thickness = opts[:thickness] || 7
      pct = [[pct.to_f, 0].max, 100].min
      nostroke
      fill col(TRACK)
      oval(left: cx - r, top: cy - r, width: r * 2, height: r * 2, fill: col(TRACK), stroke: col(TRACK))
      if pct > 0
        fill color
        arc(cx - r, cy - r, r * 2, r * 2, -Math::PI / 2, -Math::PI / 2 + TAU * pct / 100.0)
      end
      ri = r - thickness
      oval(left: cx - ri, top: cy - ri, width: ri * 2, height: ri * 2, fill: col(PANEL), stroke: col(PANEL))
      nofill
      txt("#{pct.round}%", cx - r, cy - 8, size: 12, color: TEXT, weight: "bold", width: r * 2, align: "center")
      label(opts[:label], cx - r - 10, cy + r + 6, size: 10, color: TEXT, width: r * 2 + 20, align: "center") if opts[:label]
    end

    def avatar(x, y, color, glyph, d = 30)
      oval(left: x, top: y, width: d, height: d, fill: col(color, 0.14), stroke: col(color, 0.9), strokewidth: 1)
      txt(glyph, x, y + d / 2 - 8, size: 12, color: color, width: d, align: "center")
    end

    def square_icon(x, y, color, glyph, d = 28)
      rect(left: x, top: y, width: d, height: d, curve: 6, fill: col(color, 0.14), stroke: col(color, 0.9))
      txt(glyph, x, y + d / 2 - 8, size: 12, color: color, width: d, align: "center")
    end

    def tab(x, y, text, active, opts = {})
      w = opts[:width] || (text.length * 7 + 22)
      c = opts[:color] || CYAN
      rect(left: x, top: y, width: w, height: 20, curve: 10,
           fill: active ? col(c, 0.18) : col(PANEL2),
           stroke: active ? col(c, 0.9) : col(CYAN, 0.18))
      t = txt(text, x, y + 3, size: 9, color: active ? c : MUTED, width: w, align: "center")
      t.click { yield } if block_given?
      w
    end

    # ---- charts --------------------------------------------------------

    # Multi-series line chart with grid, filled areas and point markers.
    def line_chart(x, y, w, h, labels, series, opts = {})
      max = opts[:max] || 60
      steps = opts[:steps] || 6
      pad_l = 26
      pad_b = 18
      gx = x + pad_l
      gy = y
      gw = w - pad_l
      gh = h - pad_b

      steps.downto(0) do |i|
        yy = gy + gh - (gh * i / steps.to_f)
        hline(gx, gx + gw, yy, col(CYAN, 0.08))
        label((max * i / steps).round, x, yy - 7, size: 8, width: pad_l - 6, align: "right")
      end

      n = labels.size
      return if n < 2
      xs = (0...n).map { |i| gx + (gw * i / (n - 1).to_f) }
      labels.each_with_index do |lab, i|
        vline(xs[i], gy, gy + gh, col(CYAN, 0.05))
        label(lab, xs[i] - 20, gy + gh + 4, size: 8, width: 40, align: "center")
      end

      series.each do |s|
        pts = s[:values].each_with_index.map { |v, i| [xs[i], gy + gh - (gh * [[v, 0].max, max].min / max.to_f)] }
        next if pts.size < 2
        c = s[:color]
        fill col(c, 0.1)
        nostroke
        shape do
          move_to pts.first[0], gy + gh
          pts.each { |px, py| line_to px, py }
          line_to pts.last[0], gy + gh
          line_to pts.first[0], gy + gh
        end
        nofill
        pts.each_cons(2) { |(x1, y1), (x2, y2)| line(x1, y1, x2, y2, stroke: c, strokewidth: 2) }
        pts.each { |px, py| dot(px - 2, py - 2, c, 4) }
      end
    end

    def legend(x, y, series, gap = 22)
      series.each_with_index do |s, i|
        dot(x, y + i * gap + 3, s[:color], 7)
        txt(s[:name], x + 14, y + i * gap - 2, size: 9, color: TEXT)
      end
    end
  end
end
