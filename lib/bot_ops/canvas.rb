# frozen_string_literal: true

require "json"

module BotOps
  # A toolkit-independent display list.
  #
  # Panels and widgets draw into a Canvas with absolute pixel coordinates and
  # register clickable regions. A host (lib/bot_ops/app.rb for libui, or the
  # SVG exporter below for tests and previews) then replays the commands.
  class Canvas
    Cmd = Struct.new(:op, :a)
    # Images are referred to by name; the native host embeds the same files.
    IMAGE_DIR = File.expand_path("../../ext/bot_ops_native/assets", __dir__)
    Hit = Struct.new(:x, :y, :w, :h, :handler)

    attr_reader :cmds, :hits, :width, :height

    def initialize(width, height)
      @width = width
      @height = height
      @cmds = []
      @hits = []
      @ox = 0
      @oy = 0
    end

    # Translate everything drawn inside the block by (dx, dy).
    def group(dx, dy)
      px, py = @ox, @oy
      @ox += dx
      @oy += dy
      yield
    ensure
      @ox, @oy = px, py
    end

    # ---- primitives (colours are [r, g, b, a] arrays or nil) -------------

    def rect(x, y, w, h, fill: nil, stroke: nil, curve: 0, strokewidth: 1)
      @cmds << Cmd.new(:rect, [@ox + x, @oy + y, w, h, fill, stroke, curve, strokewidth])
    end

    def circle(cx, cy, r, fill: nil, stroke: nil, strokewidth: 1)
      @cmds << Cmd.new(:circle, [@ox + cx, @oy + cy, r, fill, stroke, strokewidth])
    end

    def line(x1, y1, x2, y2, stroke:, strokewidth: 1)
      @cmds << Cmd.new(:line, [@ox + x1, @oy + y1, @ox + x2, @oy + y2, stroke, strokewidth])
    end

    # Pie wedge from start_deg sweeping sweep_deg clockwise (0 = 3 o'clock).
    def wedge(cx, cy, r, start_deg, sweep_deg, fill:)
      @cmds << Cmd.new(:wedge, [@ox + cx, @oy + cy, r, start_deg, sweep_deg, fill])
    end

    # Filled region between a polyline and a horizontal baseline (chart areas).
    def area(points, base_y, fill:)
      pts = points.map { |(x, y)| [@ox + x, @oy + y] }
      @cmds << Cmd.new(:area, [pts, @oy + base_y, fill])
    end

    # Stroked line through points; closed: true joins the last to the first.
    def polyline(points, stroke:, strokewidth: 1, closed: false)
      pts = points.map { |(x, y)| [(@ox + x).round(2), (@oy + y).round(2)] }
      @cmds << Cmd.new(:polyline, [pts, stroke, strokewidth, closed])
    end

    # Named image (ext/bot_ops_native/assets/<name>.png) clipped to a circle.
    def image_circle(name, cx, cy, r)
      @cmds << Cmd.new(:image, [name.to_s, @ox + cx, @oy + cy, r])
    end

    def text(str, x, y, size:, color:, weight: :normal, family: :sans, width: nil, align: :left, kerning: 0)
      @cmds << Cmd.new(:text, [str.to_s, @ox + x, @oy + y, size, color, weight, family, width, align, kerning])
    end

    def hit(x, y, w, h, &handler)
      @hits << Hit.new(@ox + x, @oy + y, w, h, handler)
    end

    def hit_at(x, y)
      @hits.reverse.find { |h| x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h }
    end

    def count(op = nil)
      op ? @cmds.count { |c| c.op == op } : @cmds.size
    end

    def texts
      @cmds.select { |c| c.op == :text }.map { |c| c.a[0] }
    end

    # Rough text width in pixels, used for right/centre alignment on hosts
    # whose text layout cannot measure before drawing.
    def self.text_width(str, size, weight = :normal, kerning = 0)
      factor = weight == :bold ? 0.62 : 0.56
      str.to_s.length * (size * factor + kerning)
    end

    # ---- frame export for the native host ----------------------------------

    OPS = { rect: "r", circle: "c", line: "l", wedge: "w", area: "a", text: "t", image: "i", polyline: "p" }.freeze

    # Compact JSON understood by ext/bot_ops_native (see src/lib.rs).
    # drag: the region that moves the window; resize: the grip that resizes it.
    def to_frame(drag: nil, resize: nil)
      {
        "cmds" => @cmds.map { |c| [OPS[c.op]] + encode_args(c) },
        "hits" => @hits.each_with_index.map { |h, i| [h.x, h.y, h.w, h.h, i] },
        "drag" => drag,
        "resize" => resize
      }
    end

    def to_json(drag: nil, resize: nil)
      JSON.generate(to_frame(drag: drag, resize: resize))
    end

    # ---- SVG export (tests, previews) -------------------------------------

    def to_svg
      out = +%(<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" font-family="DejaVu Sans, sans-serif">)
      @cmds.each do |c|
        case c.op
        when :rect
          x, y, w, h, f, s, r, sw = c.a
          out << %(<rect x="#{x}" y="#{y}" width="#{w}" height="#{h}" rx="#{r}" fill="#{svg_c(f)}" stroke="#{svg_c(s)}" stroke-width="#{sw}"/>)
        when :circle
          x, y, r, f, s, sw = c.a
          out << %(<circle cx="#{x}" cy="#{y}" r="#{r}" fill="#{svg_c(f)}" stroke="#{svg_c(s)}" stroke-width="#{sw}"/>)
        when :line
          x1, y1, x2, y2, s, sw = c.a
          out << %(<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" stroke="#{svg_c(s)}" stroke-width="#{sw}"/>)
        when :wedge
          cx, cy, r, a1, sweep, f = c.a
          r1 = a1 * Math::PI / 180
          r2 = (a1 + sweep) * Math::PI / 180
          large = sweep.abs > 180 ? 1 : 0
          out << %(<path d="M #{cx} #{cy} L #{cx + r * Math.cos(r1)} #{cy + r * Math.sin(r1)} A #{r} #{r} 0 #{large} 1 #{cx + r * Math.cos(r2)} #{cy + r * Math.sin(r2)} Z" fill="#{svg_c(f)}"/>)
        when :area
          pts, base, f = c.a
          poly = [[pts.first[0], base]] + pts + [[pts.last[0], base]]
          out << %(<polygon points="#{poly.map { |p| p.join(',') }.join(' ')}" fill="#{svg_c(f)}"/>)
        when :polyline
          pts, s, sw, closed = c.a
          tag = closed ? "polygon" : "polyline"
          out << %(<#{tag} points="#{pts.map { |p| p.join(',') }.join(' ')}" fill="none" stroke="#{svg_c(s)}" stroke-width="#{sw}" stroke-linejoin="round"/>)
        when :image
          name, cx, cy, r = c.a
          path = File.join(IMAGE_DIR, "#{name}.png")
          next unless File.exist?(path)
          id = "clip-#{name}-#{cx.round}-#{cy.round}"
          out << %(<clipPath id="#{id}"><circle cx="#{cx}" cy="#{cy}" r="#{r}"/></clipPath>)
          out << %(<image x="#{cx - r}" y="#{cy - r}" width="#{r * 2}" height="#{r * 2}" clip-path="url(##{id})" ) +
                 %(href="data:image/png;base64,#{[File.binread(path)].pack("m0")}"/>)
        when :text
          str, x, y, size, color, weight, family, width, align, kerning = c.a
          anchor = { left: "start", center: "middle", right: "end" }[align]
          tx = x
          tx += width / 2.0 if align == :center && width
          tx += width if align == :right && width
          fam = family == :mono ? "DejaVu Sans Mono, monospace" : "DejaVu Sans, sans-serif"
          esc = str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
          out << %(<text x="#{tx}" y="#{y + size}" font-size="#{size}" fill="#{svg_c(color)}" font-weight="#{weight}" text-anchor="#{anchor}" letter-spacing="#{kerning}" font-family="#{fam}">#{esc}</text>)
        end
      end
      out << "</svg>"
    end

    private

    def encode_args(c)
      a = c.a
      case c.op
      when :text then a[0, 5] + [a[5].to_s, a[6].to_s, a[7], a[8].to_s, a[9]]
      else a
      end
    end

    def svg_c(c)
      return "none" if c.nil?
      format("rgba(%d,%d,%d,%.3f)", c[0], c[1], c[2], c[3])
    end
  end
end
