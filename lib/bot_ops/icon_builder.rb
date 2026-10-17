# frozen_string_literal: true

require "net/http"
require "uri"

module BotOps
  # Builds lib/bot_ops/icons.rb from Lucide's SVG icons (https://lucide.dev,
  # ISC license): every element is flattened to polylines in Lucide's 24x24
  # box, so the native side strokes them like any other line. Run with
  # `rake icons`; the generated file is committed, so the app never fetches.
  module IconBuilder
    VERSION = "1.55.0"
    SOURCE = "https://unpkg.com/lucide-static@#{VERSION}/icons/%s.svg"
    PATH = File.expand_path("icons.rb", __dir__)

    NAMES = %w[
      activity alarm-clock app-window bot calendar chart-line chart-no-axes-column chevron-down chevron-right circle-alert circle-dot
      clock code-xml cpu database diamond folder-git-2 git-merge hexagon history house info layers maximize-2
      message-square message-square-text minus monitor scroll-text server settings square-activity wrench x zap
    ].freeze

    # Brand marks Lucide doesn't draw, as path data in a 24x24 box. The
    # Visual Studio Code mark is from Simple Icons (CC0); the logo is a
    # trademark of Microsoft, used here to label sessions run in VS Code.
    EXTRA = {
      "vscode" => "M23.15 2.587L18.21.21a1.494 1.494 0 0 0-1.705.29l-9.46 8.63-4.12-3.128a.999.999 0 0 0-1.276.057L.327 7.261" \
                  "A1 1 0 0 0 .326 8.74L3.899 12 .326 15.26a1 1 0 0 0 .001 1.479L1.65 17.94a.999.999 0 0 0 1.276.057l4.12-3.128 " \
                  "9.46 8.63a1.492 1.492 0 0 0 1.704.29l4.942-2.377A1.5 1.5 0 0 0 24 20.06V3.939a1.5 1.5 0 0 0-.85-1.352z" \
                  "m-5.146 14.861L10.826 12l7.178-5.448v10.896z"
    }.freeze

    # The cloud, traced from the designer's drawing (a 1088x656 tracing of
    # it): three lobes on top, wide rounded corners below, and a bottom that
    # is one long, barely curved line. The outline is where the union of
    # these shapes ends, smoothed (CLOUD_SMOOTHING passes) so the dips
    # between lobes are soft; it's star-shaped around CLOUD_ORIGIN.
    CLOUD_CIRCLES  = [[560, 238, 118], [386, 288, 67], [722, 285, 68]].freeze
    CLOUD_ELLIPSES = [[302, 390, 77, 90], [790, 390, 85, 91]].freeze
    CLOUD_ARCS     = [[546, 487 - 4256, 4256, 302, 790]].freeze # circle, x range: a gentle sag between the corners
    CLOUD_BODY     = [300, 300, 800, 420].freeze
    CLOUD_ORIGIN   = [550, 370].freeze
    CLOUD_SMOOTHING = 24

    module_function

    def cloud_sdf(px, py)
      d = CLOUD_CIRCLES.map { |cx, cy, r| Math.hypot(px - cx, py - cy) - r }
      d += CLOUD_ELLIPSES.map { |cx, cy, rx, ry| (Math.hypot((px - cx) / rx, (py - cy) / ry) - 1) * [rx, ry].min }
      d += CLOUD_ARCS.map { |cx, cy, r, x0, x1| [Math.hypot(px - cx, py - cy) - r, 380 - py, x0 - px, px - x1].max }
      x0, y0, x1, y1 = CLOUD_BODY
      d << [x0 - px, px - x1, y0 - py, py - y1].max
      d.min
    end

    # [[closed, points]] in the 24-unit box (20 wide, centred), and the
    # point the outline is star-shaped around (for filling it).
    def cloud
      ox, oy = CLOUD_ORIGIN
      raw = (0...180).map do |i|
        a = 2 * Math::PI * i / 180
        dx, dy = Math.cos(a), Math.sin(a)
        m = 600.0
        m -= 2 while m > 0 && cloud_sdf(ox + m * dx, oy + m * dy) > 0 # the outermost edge along the ray
        lo, hi = m, m + 2
        30.times { mid = (lo + hi) / 2; cloud_sdf(ox + mid * dx, oy + mid * dy) <= 0 ? lo = mid : hi = mid }
        [ox + lo * dx, oy + lo * dy]
      end
      raw = resample(chaikin(raw, 2), 240)
      CLOUD_SMOOTHING.times do
        raw = raw.each_index.map do |i|
          a, b, c = raw[i - 1], raw[i], raw[(i + 1) % raw.size]
          [(a[0] + 2 * b[0] + c[0]) / 4.0, (a[1] + 2 * b[1] + c[1]) / 4.0]
        end
      end
      raw = resample(raw, 120)
      xs, ys = raw.map(&:first), raw.map(&:last)
      k = 20.0 / (xs.max - xs.min)
      mx, my = (xs.max + xs.min) / 2, (ys.max + ys.min) / 2
      to_box = ->(x, y) { [12 + (x - mx) * k, 12 + (y - my) * k] }
      [[[true, raw.map { |x, y| to_box.(x, y) }]], to_box.(ox, oy)]
    end

    # Corner-cutting on a closed outline: softens the notches between lobes
    # the way the drawing's thick line does (and keeps thick strokes from
    # spiking there).
    def chaikin(pts, times)
      times.times do
        pts = pts.each_with_index.flat_map do |(x, y), i|
          nx, ny = pts[(i + 1) % pts.size]
          [[0.75 * x + 0.25 * nx, 0.75 * y + 0.25 * ny], [0.25 * x + 0.75 * nx, 0.25 * y + 0.75 * ny]]
        end
      end
      pts
    end

    # `n` points evenly spaced along a closed outline.
    def resample(pts, n)
      segs = pts.each_with_index.map { |p, i| [p, pts[(i + 1) % pts.size]] }
      lens = segs.map { |(a, b)| Math.hypot(b[0] - a[0], b[1] - a[1]) }
      total = lens.sum
      out = []
      i = 0
      walked = 0.0
      n.times do |j|
        target = total * j / n
        while walked + lens[i] < target
          walked += lens[i]
          i += 1
        end
        (a, b), t = segs[i], (target - walked) / lens[i]
        out << [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
      end
      out
    end

    def build(names = NAMES)
      icons = names.to_h { |n| [n, flatten_svg(fetch(n))] }
      EXTRA.each { |name, d| icons[name] = path(d) }
      icons["cloud"], cloud_origin = cloud
      body = icons.map do |name, lines|
        polys = lines.map { |closed, pts| "[#{closed}, #{pts.flatten.map { |v| v.round(2) }.inspect}]" }
        "    #{name.inspect} => [\n      #{polys.join(",\n      ")}\n    ]"
      end
      origin = cloud_origin.map { |v| v.round(2) }
      File.write(PATH, <<~RUBY)
        # frozen_string_literal: true

        # GENERATED by `rake icons` from Lucide #{VERSION} (https://lucide.dev),
        # ISC License, Copyright (c) Lucide Contributors; "vscode" is the Visual
        # Studio Code mark from Simple Icons (CC0), a Microsoft trademark;
        # "cloud" is traced from the designer's drawing (IconBuilder.cloud).
        # Don't edit by hand.
        #
        # Each icon is a list of [closed, [x0, y0, x1, y1, ...]] polylines in a
        # 24x24 box, drawn with a 2-unit stroke and round caps.
        module BotOps
          ICONS = {
        #{body.join(",\n")}
          }.freeze

          # Where the cloud's outline is star-shaped around, to fill it.
          CLOUD_ORIGIN = #{origin.inspect}.freeze
        end
      RUBY
      icons.size
    end

    def fetch(name)
      res = Net::HTTP.get_response(URI(format(SOURCE, name)))
      res = Net::HTTP.get_response(URI(res["location"])) if res.is_a?(Net::HTTPRedirection)
      raise "#{name}: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
      res.body
    end

    # [[closed, [[x, y], ...]], ...] for every shape in the SVG.
    def flatten_svg(svg)
      svg.scan(/<(path|circle|rect|line|polyline|polygon|ellipse)\b([^>]*)>/).flat_map do |tag, attrs|
        a = attrs.scan(/([\w-]+)="([^"]*)"/).to_h { |k, v| [k, v] }
        f = ->(k, default = 0) { (a[k] || default).to_f }
        case tag
        when "path" then path(a["d"])
        when "circle" then [[true, ellipse(f.("cx"), f.("cy"), f.("r"), f.("r"))]]
        when "ellipse" then [[true, ellipse(f.("cx"), f.("cy"), f.("rx"), f.("ry"))]]
        when "line" then [[false, [[f.("x1"), f.("y1")], [f.("x2"), f.("y2")]]]]
        when "polyline", "polygon"
          pts = a["points"].scan(/-?[\d.]+/).map(&:to_f).each_slice(2).to_a
          [[tag == "polygon", pts]]
        when "rect"
          rx = a["rx"] ? f.("rx") : f.("ry")
          [[true, rounded_rect(f.("x"), f.("y"), f.("width"), f.("height"), rx)]]
        end
      end
    end

    def ellipse(cx, cy, rx, ry)
      n = [[(([rx, ry].max) * 6).round, 16].max, 48].min
      (0...n).map { |i| t = 2 * Math::PI * i / n; [cx + rx * Math.cos(t), cy + ry * Math.sin(t)] }
    end

    def rounded_rect(x, y, w, h, r)
      r = [r, w / 2, h / 2].min
      return [[x, y], [x + w, y], [x + w, y + h], [x, y + h]] if r <= 0
      [[x + w - r, y + r, -90], [x + w - r, y + h - r, 0], [x + r, y + h - r, 90], [x + r, y + r, 180]].flat_map do |cx, cy, a0|
        (0..4).map { |i| t = (a0 + 22.5 * i) * Math::PI / 180; [cx + r * Math.cos(t), cy + r * Math.sin(t)] }
      end
    end

    # SVG path data -> polylines (curves and arcs flattened).
    def path(d)
      tokens = []
      number = /-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?/
      d.scan(/([MmLlHhVvCcSsQqTtAaZz])([^MmLlHhVvCcSsQqTtAaZz]*)/) do |c, args|
        tokens << c
        if c.match?(/[Aa]/)
          # Arc flags are single digits and may run together ("00-2.4").
          rest = args
          arc_args = /\A[\s,]*(#{number})[\s,]*(#{number})[\s,]*(#{number})[\s,]*([01])[\s,]*([01])[\s,]*(#{number})[\s,]*(#{number})/
          while (m = rest.match(arc_args))
            tokens.concat(m.captures)
            rest = m.post_match
          end
        else
          tokens.concat(args.scan(number))
        end
      end
      out = []
      cur = nil
      x = y = 0.0
      sx = sy = 0.0
      last_ctrl = nil
      cmd = nil
      take = ->(n) { Array.new(n) { tokens.shift.to_f } }
      until tokens.empty?
        cmd = tokens.shift if tokens.first.match?(/\A[A-Za-z]\z/)
        rel = cmd == cmd.downcase
        ox, oy = rel ? [x, y] : [0.0, 0.0]
        case cmd.upcase
        when "M"
          nx, ny = take.(2)
          x, y = ox + nx, oy + ny
          sx, sy = x, y
          out << (cur = [false, [[x, y]]])
          cmd = rel ? "l" : "L" # further pairs are line-tos
          last_ctrl = nil
        when "L"
          nx, ny = take.(2)
          x, y = ox + nx, oy + ny
          cur[1] << [x, y]
          last_ctrl = nil
        when "H"
          x = (rel ? x : 0.0) + take.(1)[0]
          cur[1] << [x, y]
          last_ctrl = nil
        when "V"
          y = (rel ? y : 0.0) + take.(1)[0]
          cur[1] << [x, y]
          last_ctrl = nil
        when "C", "S"
          if cmd.upcase == "C"
            x1, y1, x2, y2, ex, ey = take.(6)
            c1 = [ox + x1, oy + y1]
          else
            x2, y2, ex, ey = take.(4)
            c1 = last_ctrl ? [2 * x - last_ctrl[0], 2 * y - last_ctrl[1]] : [x, y]
          end
          c2 = [ox + x2, oy + y2]
          e = [ox + ex, oy + ey]
          cubic([x, y], c1, c2, e).each { |p| cur[1] << p }
          last_ctrl = c2
          x, y = e
        when "Q", "T"
          if cmd.upcase == "Q"
            x1, y1, ex, ey = take.(4)
            c = [ox + x1, oy + y1]
          else
            ex, ey = take.(2)
            c = last_ctrl ? [2 * x - last_ctrl[0], 2 * y - last_ctrl[1]] : [x, y]
          end
          e = [ox + ex, oy + ey]
          c1 = [x + 2.0 / 3 * (c[0] - x), y + 2.0 / 3 * (c[1] - y)]
          c2 = [e[0] + 2.0 / 3 * (c[0] - e[0]), e[1] + 2.0 / 3 * (c[1] - e[1])]
          cubic([x, y], c1, c2, e).each { |p| cur[1] << p }
          last_ctrl = c
          x, y = e
        when "A"
          rx, ry, rot, large, sweep, ex, ey = take.(7)
          e = [ox + ex, oy + ey]
          arc([x, y], rx, ry, rot, large != 0, sweep != 0, e).each { |p| cur[1] << p }
          x, y = e
          last_ctrl = nil
        when "Z"
          cur[0] = true
          cur[1].pop if cur[1].size > 1 && cur[1].last.zip(cur[1].first).all? { |a, b| (a - b).abs < 1e-6 }
          x, y = sx, sy
          last_ctrl = nil
        end
      end
      out.reject { |_, pts| pts.size < 2 }
    end

    def cubic(p0, p1, p2, p3)
      len = [p0, p1, p2, p3].each_cons(2).sum { |a, b| Math.hypot(b[0] - a[0], b[1] - a[1]) }
      n = [[(len * 1.5).ceil, 4].max, 24].min
      (1..n).map do |i|
        t = i.to_f / n
        u = 1 - t
        [0, 1].map { |k| u**3 * p0[k] + 3 * u * u * t * p1[k] + 3 * u * t * t * p2[k] + t**3 * p3[k] }
      end
    end

    # SVG endpoint arc -> points (SVG 1.1 implementation notes, F.6.5).
    def arc(p0, rx, ry, rot_deg, large, sweep, p1)
      return [p1] if rx.zero? || ry.zero?
      rx, ry = rx.abs, ry.abs
      phi = rot_deg * Math::PI / 180
      cp, sp = Math.cos(phi), Math.sin(phi)
      dx, dy = (p0[0] - p1[0]) / 2.0, (p0[1] - p1[1]) / 2.0
      x1 = cp * dx + sp * dy
      y1 = -sp * dx + cp * dy
      lam = x1**2 / rx**2 + y1**2 / ry**2
      if lam > 1
        rx *= Math.sqrt(lam)
        ry *= Math.sqrt(lam)
      end
      num = rx**2 * ry**2 - rx**2 * y1**2 - ry**2 * x1**2
      den = rx**2 * y1**2 + ry**2 * x1**2
      coef = Math.sqrt([num / den, 0].max) * (large == sweep ? -1 : 1)
      cx1 = coef * rx * y1 / ry
      cy1 = -coef * ry * x1 / rx
      cx = cp * cx1 - sp * cy1 + (p0[0] + p1[0]) / 2.0
      cy = sp * cx1 + cp * cy1 + (p0[1] + p1[1]) / 2.0
      ang = ->(ux, uy, vx, vy) { Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
      t1 = ang.(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
      dt = ang.((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
      dt -= 2 * Math::PI if !sweep && dt.positive?
      dt += 2 * Math::PI if sweep && dt.negative?
      n = [[(dt.abs * [rx, ry].max * 1.2).ceil, 3].max, 32].min
      (1..n).map do |i|
        t = t1 + dt * i / n
        [cx + rx * Math.cos(t) * cp - ry * Math.sin(t) * sp, cy + rx * Math.cos(t) * sp + ry * Math.sin(t) * cp]
      end
    end
  end
end
