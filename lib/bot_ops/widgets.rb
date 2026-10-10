# frozen_string_literal: true

module BotOps
  # Drawing helpers on top of Canvas. Mixed into Scene, which provides @c
  # (the canvas being built), @store and @host.
  module Widgets
    include Theme

    # ---- colours -------------------------------------------------------

    def col(hex, alpha = 1.0)
      r, g, b = Theme.hex_rgb(hex)
      [r, g, b, alpha.to_f]
    end

    # ---- text ----------------------------------------------------------

    def txt(str, x, y, opts = {})
      @c.text(str, x, y,
              size: opts[:size] || 11,
              color: col(opts[:color] || TEXT),
              weight: opts[:weight] ? opts[:weight].to_sym : :normal,
              family: opts[:mono] ? :mono : :sans,
              width: opts[:width],
              align: (opts[:align] || :left).to_sym,
              kerning: opts[:kerning] || 0)
    end

    def label(str, x, y, opts = {})
      txt(str, x, y, { size: 9, color: MUTED }.merge(opts))
    end

    # Truncate text that would otherwise run into the next column.
    def clip(str, max_chars)
      s = str.to_s
      s.length > max_chars ? "#{s[0, [max_chars - 1, 1].max]}…" : s
    end

    # ---- boxes ---------------------------------------------------------

    def box(x, y, w, h, opts = {})
      @c.rect(x, y, w, h,
              curve: opts[:curve] || 6,
              fill: opts[:fill] || col(PANEL2),
              stroke: opts[:stroke] || col(EDGE_SOFT, 0.8),
              strokewidth: opts[:strokewidth] || 1)
    end

    def hline(x1, x2, y, color = col(CYAN, 0.12), width = 1)
      @c.line(x1, y, x2, y, stroke: color, strokewidth: width)
    end

    def vline(x, y1, y2, color = col(CYAN, 0.12), width = 1)
      @c.line(x, y1, x, y2, stroke: color, strokewidth: width)
    end

    # Filled circle whose top-left corner is (x, y) and diameter d.
    def dot(x, y, color, d = 6)
      @c.circle(x + d / 2.0, y + d / 2.0, d / 2.0, fill: color)
    end

    def glow_dot(x, y, color, d = 6)
      @c.circle(x + d / 2.0, y + d / 2.0, d / 2.0 + 3, fill: [color[0], color[1], color[2], 0.18])
      dot(x, y, color, d)
    end

    # A framed dashboard panel. The block draws the body with its origin at
    # the panel's top-left corner just below the title bar.
    def panel(x, y, w, h, opts = {})
      @c.rect(x, y, w, h, curve: 7, fill: col(PANEL))
      electric_frame(x, y, w, h, curve: 7)
      if opts[:title]
        txt(opts[:title], x + 16, y + 11, size: 11, color: TEXT, weight: :bold, kerning: 1)
        fade_line(x + 10, x + w - 10, y + Layout::PANEL_TITLE_H - 1, BOLT)
      end
      if opts[:right]
        rw = opts[:right_w] || 120
        txt(opts[:right], x + w - 16 - rw, y + 11, size: 10, color: opts[:right_color] || CYAN, width: rw, align: :right)
      end
      @c.group(x, y + Layout::PANEL_TITLE_H) { yield } if block_given?
    end

    # Lightning-style outline: a wide faint halo, a brighter glow, a bright
    # electric core with a white-hot hairline, glowing corner brackets, and a
    # jagged spark on the top and bottom edges. The sparks are seeded by
    # position, so each frame has its own bolt and it never flickers.
    def electric_frame(x, y, w, h, curve: 7)
      @c.rect(x - 2, y - 2, w + 4, h + 4, curve: curve + 2, stroke: col(EDGE, 0.16), strokewidth: 7)
      @c.rect(x - 0.5, y - 0.5, w + 1, h + 1, curve: curve + 0.5, stroke: col(BOLT, 0.35), strokewidth: 3)
      @c.rect(x, y, w, h, curve: curve, stroke: col(BOLT), strokewidth: 1.4)
      @c.rect(x, y, w, h, curve: curve, stroke: col(SPARK, 0.45), strokewidth: 0.5)

      arm = [[w, h].min / 6, 22].min
      [[x, y, 1, 1], [x + w, y, -1, 1], [x, y + h, 1, -1], [x + w, y + h, -1, -1]].each do |cx, cy, sx, sy|
        [[[cx + sx * curve, cy], [cx + sx * (curve + arm), cy]],
         [[cx, cy + sy * curve], [cx, cy + sy * (curve + arm)]]].each do |(x1, y1), (x2, y2)|
          @c.line(x1, y1, x2, y2, stroke: col(CYAN, 0.35), strokewidth: 4)
          @c.line(x1, y1, x2, y2, stroke: col(SPARK, 0.95), strokewidth: 1.4)
        end
      end

      rng = Random.new((x * 73 + y * 31 + w).to_i)
      spark(x + w * (0.55 + rng.rand * 0.15), y, [w * 0.18, 140].min, rng)
      spark(x + w * (0.08 + rng.rand * 0.15), y + h, [w * 0.12, 90].min, rng)
    end

    # A jagged bolt along a horizontal edge: glow first, then the hot core.
    def spark(x, y, len, rng)
      n = 9
      pts = (0..n).map { |i| [x + len * i / n, y + (i.zero? || i == n ? 0 : (rng.rand * 5 - 2.5))] }
      [[col(BOLT, 0.3), 4], [col(CYAN, 0.8), 1.6], [col(SPARK), 0.7]].each do |c, sw|
        pts.each_cons(2) { |(x1, y1), (x2, y2)| @c.line(x1, y1, x2, y2, stroke: c, strokewidth: sw) }
      end
      @c.circle(pts.last[0], pts.last[1], 2.2, fill: col(SPARK, 0.9))
      @c.circle(pts.last[0], pts.last[1], 5, fill: col(CYAN, 0.18))
    end

    # A divider that is brightest on the left and fades out to the right.
    def fade_line(x1, x2, y, color_hex)
      steps = 8
      seg = (x2 - x1) / steps.to_f
      steps.times do |i|
        a = 0.55 * (1 - i / steps.to_f)**1.6
        @c.line(x1 + seg * i, y, x1 + seg * (i + 1), y, stroke: col(color_hex, a), strokewidth: 1)
      end
    end

    # ---- indicators ----------------------------------------------------

    def status_pill(x, y, status, opts = {})
      c = Theme.status_color(status)
      dot(x, y + 4, col(c), 6)
      txt(status, x + 10, y - 1, size: opts[:size] || 9, color: c)
    end

    def priority_pill(x, y, priority)
      c = Theme.priority_color(priority)
      dot(x, y + 4, col(c), 6)
      txt(priority, x + 10, y - 1, size: 9, color: c)
    end

    def hbar(x, y, w, h, pct, color_hex, opts = {})
      pct = [[pct.to_f, 0].max, 100].min
      @c.rect(x, y, w, h, curve: h / 2.0, fill: col(TRACK))
      fw = (w * pct / 100.0).round
      return unless fw > 0
      @c.rect(x, y, [fw, h].max, h, curve: h / 2.0, fill: col(color_hex))
      @c.rect(x, y - 1, [fw, h].max, h + 2, curve: h / 2.0, stroke: col(color_hex, 0.25)) unless opts[:no_glow]
    end

    # Circular gauge: track ring, coloured arc, percentage inside.
    def donut(cx, cy, r, pct, color_hex, opts = {})
      thickness = opts[:thickness] || 7
      pct = [[pct.to_f, 0].max, 100].min
      @c.circle(cx, cy, r, fill: col(TRACK))
      @c.wedge(cx, cy, r, -90, 360.0 * pct / 100.0, fill: col(color_hex)) if pct > 0
      @c.circle(cx, cy, r - thickness, fill: col(PANEL))
      txt("#{pct.round}%", cx - r, cy - 8, size: 12, color: TEXT, weight: :bold, width: r * 2, align: :center)
      label(opts[:label], cx - r - 10, cy + r + 6, size: 10, color: TEXT, width: r * 2 + 20, align: :center) if opts[:label]
    end

    def avatar(x, y, color_hex, glyph, d = 30)
      @c.circle(x + d / 2.0, y + d / 2.0, d / 2.0, fill: col(color_hex, 0.14), stroke: col(color_hex, 0.9))
      txt(glyph, x, y + d / 2 - 8, size: 12, color: color_hex, width: d, align: :center)
    end

    def square_icon(x, y, color_hex, glyph, d = 28)
      @c.rect(x, y, d, d, curve: 6, fill: col(color_hex, 0.14), stroke: col(color_hex, 0.9))
      txt(glyph, x, y + d / 2 - 8, size: 12, color: color_hex, width: d, align: :center)
    end

    # Pill-shaped tab; returns its width. The block runs when it is clicked.
    def tab(x, y, text, active, opts = {}, &on_click)
      w = opts[:width] || (text.length * 7 + 22)
      c = opts[:color] || CYAN
      @c.rect(x, y, w, 20, curve: 10,
              fill: active ? col(c, 0.18) : col(PANEL2),
              stroke: active ? col(c, 0.9) : col(EDGE_SOFT, 0.8))
      txt(text, x, y + 3, size: 9, color: active ? c : MUTED, width: w, align: :center)
      @c.hit(x, y, w, 20, &on_click) if on_click
      w
    end

    # Text that acts as a button.
    def link(text, x, y, opts = {}, &on_click)
      size = opts[:size] || 9
      txt(text, x, y, { size: size, color: CYAN }.merge(opts))
      w = opts[:width] || Canvas.text_width(text, size)
      @c.hit(x - 2, y - 2, w + 4, size + 8, &on_click)
    end

    # ---- charts --------------------------------------------------------

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
        label((max * i / steps).round, x, yy - 7, size: 8, width: pad_l - 6, align: :right)
      end

      n = labels.size
      return if n < 2
      xs = (0...n).map { |i| gx + (gw * i / (n - 1).to_f) }
      labels.each_with_index do |lab, i|
        vline(xs[i], gy, gy + gh, col(CYAN, 0.05))
        label(lab, xs[i] - 20, gy + gh + 4, size: 8, width: 40, align: :center)
      end

      series.each do |s|
        pts = s[:values].each_with_index.map { |v, i| [xs[i], gy + gh - (gh * [[v, 0].max, max].min / max.to_f)] }
        next if pts.size < 2
        c = col(s[:color])
        @c.area(pts, gy + gh, fill: col(s[:color], 0.06))
        pts.each_cons(2) { |(x1, y1), (x2, y2)| @c.line(x1, y1, x2, y2, stroke: c, strokewidth: 2) }
        pts.each { |px, py| @c.circle(px, py, 2, fill: c) }
      end
    end

    def legend(x, y, series, gap = 22)
      series.each_with_index do |s, i|
        dot(x, y + i * gap + 3, col(s[:color]), 7)
        txt(s[:name], x + 14, y + i * gap - 2, size: 9, color: TEXT)
      end
    end
  end
end
