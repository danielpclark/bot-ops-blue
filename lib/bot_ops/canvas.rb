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

    # Filled region between a polyline and a horizontal baseline (chart
    # areas). With `fade` it runs from `fill` at y = top_y to `fade` at the
    # baseline.
    def area(points, base_y, fill:, fade: nil, top_y: nil)
      pts = points.map { |(x, y)| [@ox + x, @oy + y] }
      args = [pts, @oy + base_y, fill]
      args += [fade, @oy + (top_y || points.map(&:last).min)] if fade
      @cmds << Cmd.new(:area, args)
    end

    # Stroked line through points; closed: true joins the last to the first;
    # round: true rounds its ends and sharp corners (icons).
    def polyline(points, stroke:, strokewidth: 1, closed: false, round: false)
      pts = points.map { |(x, y)| [(@ox + x).round(2), (@oy + y).round(2)] }
      @cmds << Cmd.new(:polyline, [pts, stroke, strokewidth, closed, round])
    end

    # A convex polygon filled with a linear gradient, `from` colour at
    # (x1, y1) to `to` at (x2, y2). A polygon that isn't convex but is
    # star-shaped around some point can be filled by passing it as `center`.
    def gradient(points, x1, y1, x2, y2, from:, to:, center: nil)
      pts = points.map { |(x, y)| [(@ox + x).round(2), (@oy + y).round(2)] }
      args = [pts, [@ox + x1, @oy + y1, @ox + x2, @oy + y2], from, to]
      args << [(@ox + center[0]).round(2), (@oy + center[1]).round(2)] if center
      @cmds << Cmd.new(:gradient, args)
    end

    # A soft glow around a rounded rectangle (blur: how far it fades out).
    def glow(x, y, w, h, color:, curve: 0, blur: 12, spread: 0)
      @cmds << Cmd.new(:glow, [@ox + x, @oy + y, w, h, curve, blur, spread, color])
    end

    # Outline of a rounded rectangle, clockwise, for #gradient.
    def self.rounded_rect(x, y, w, h, r, steps: 6)
      r = [[r, w / 2.0, h / 2.0].min, 0].max
      return [[x, y], [x + w, y], [x + w, y + h], [x, y + h]] if r.zero?
      [[x + w - r, y + r, -90], [x + w - r, y + h - r, 0], [x + r, y + h - r, 90], [x + r, y + r, 180]].flat_map do |cx, cy, a0|
        (0..steps).map { |i| a = (a0 + 90.0 * i / steps) * Math::PI / 180; [cx + r * Math.cos(a), cy + r * Math.sin(a)] }
      end
    end

    def self.circle_points(cx, cy, r, steps: nil)
      steps ||= [[(r * 1.6).round, 24].max, 72].min
      (0...steps).map { |i| a = 2 * Math::PI * i / steps; [cx + r * Math.cos(a), cy + r * Math.sin(a)] }
    end

    # Draws the block's commands clipped to x, y, w, h: nothing in it shows
    # outside that rectangle. Clips nest (each is cut to its parent's).
    def clip(x, y, w, h)
      @cmds << Cmd.new(:clip, [@ox + x, @oy + y, w, h])
      yield
    ensure
      @cmds << Cmd.new(:unclip, [])
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

    # A region over the whole window, whatever group is open: a menu closes
    # on a click anywhere else, so it adds this before its own regions.
    def hit_everywhere(&handler)
      @hits << Hit.new(0, 0, @width, @height, handler)
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

    OPS = { rect: "r", circle: "c", line: "l", wedge: "w", area: "a", text: "t", image: "i", polyline: "p", clip: "k",
            unclip: "K", gradient: "g", glow: "s" }.freeze

    # Compact JSON understood by ext/bot_ops_native (see src/lib.rs).
    # drag: the region that moves the window; resize: the grip that resizes
    # it; pan: where a drag pans the content (an open overlay's body).
    def to_frame(drag: nil, resize: nil, pan: nil, badge: 0, bg: nil)
      {
        "badge" => badge,
        "bg" => bg,
        "cmds" => @cmds.map { |c| [OPS[c.op]] + encode_args(c) },
        "hits" => @hits.each_with_index.map { |h, i| [h.x, h.y, h.w, h.h, i] },
        "drag" => drag,
        "resize" => resize,
        "pan" => pan
      }
    end

    def to_json(drag: nil, resize: nil, pan: nil, badge: 0, bg: nil)
      JSON.generate(to_frame(drag: drag, resize: resize, pan: pan, badge: badge, bg: bg))
    end

    # ---- SVG export (tests, previews) -------------------------------------

    SVG_FONTS = { sans: "Inter, sans-serif", mono: "DejaVu Sans Mono, monospace", display: "Montserrat, sans-serif" }.freeze
    SVG_WEIGHTS = { normal: 400, medium: 500, semibold: 600, bold: 700 }.freeze

    def to_svg
      out = +%(<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" width="#{@width}" height="#{@height}" font-family="Inter, sans-serif">)
      clips = 0
      defs = 0
      @cmds.each do |c|
        case c.op
        when :clip
          x, y, w, h = c.a
          clips += 1
          out << %(<clipPath id="cut#{clips}"><rect x="#{x}" y="#{y}" width="#{w}" height="#{h}"/></clipPath><g clip-path="url(#cut#{clips})">)
        when :unclip
          out << "</g>"
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
          pts, base, f, fade, top = c.a
          poly = [[pts.first[0], base]] + pts + [[pts.last[0], base]]
          fill = svg_c(f)
          if fade
            defs += 1
            out << svg_gradient("g#{defs}", 0, top, 0, base, f, fade)
            fill = "url(#g#{defs})"
          end
          out << %(<polygon points="#{poly.map { |p| p.join(',') }.join(' ')}" fill="#{fill}"/>)
        when :polyline
          pts, s, sw, closed, round = c.a
          tag = closed ? "polygon" : "polyline"
          cap = round ? %( stroke-linecap="round") : ""
          out << %(<#{tag} points="#{pts.map { |p| p.join(',') }.join(' ')}" fill="none" stroke="#{svg_c(s)}" stroke-width="#{sw}" stroke-linejoin="round"#{cap}/>)
        when :gradient
          pts, (x1, y1, x2, y2), from, to = c.a
          defs += 1
          out << svg_gradient("g#{defs}", x1, y1, x2, y2, from, to)
          out << %(<polygon points="#{pts.map { |p| p.join(',') }.join(' ')}" fill="url(#g#{defs})"/>)
        when :glow
          x, y, w, h, r, blur, spread, color = c.a
          defs += 1
          out << %(<filter id="b#{defs}" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="#{blur / 2.0}"/></filter>)
          out << %(<rect x="#{x - spread}" y="#{y - spread}" width="#{w + spread * 2}" height="#{h + spread * 2}" rx="#{r + spread}" ) +
                 %(fill="#{svg_c(color)}" filter="url(#b#{defs})"/>)
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
          fam = SVG_FONTS[family] || SVG_FONTS[:sans]
          esc = str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
          wt = family == :display ? 800 : SVG_WEIGHTS[weight] || 400
          out << %(<text x="#{tx}" y="#{y + size * 0.93}" font-size="#{size}" fill="#{svg_c(color)}" font-weight="#{wt}" text-anchor="#{anchor}" letter-spacing="#{kerning}" font-family="#{fam}" style="white-space:pre">#{esc}</text>)
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

    def svg_gradient(id, x1, y1, x2, y2, from, to)
      %(<linearGradient id="#{id}" gradientUnits="userSpaceOnUse" x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}">) +
        %(<stop offset="0" stop-color="#{svg_c(from)}"/><stop offset="1" stop-color="#{svg_c(to)}"/></linearGradient>)
    end

    def svg_c(c)
      return "none" if c.nil?
      format("rgba(%d,%d,%d,%.3f)", c[0], c[1], c[2], c[3])
    end
  end
end
