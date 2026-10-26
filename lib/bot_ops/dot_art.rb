# frozen_string_literal: true

require "digest"

module BotOps
  # Dot-matrix sprites for the Bots page: small grids of lit and unlit cells
  # that Widgets#dot_sprite draws as glowing dots. Pure functions, no drawing.
  #
  # A sprite is { "rows" => ["..##..", ...], "palette" => { "#" => colour } }.
  # Each row is a string, "." an unlit cell and any other character a cell
  # coloured by the palette (a theme colour name or "#RRGGBB"). Themes may
  # supply sprites per bot or per status (Theme, `art:`); a bot without one
  # gets a generated identicon, a symmetric robot face hashed from its name.
  module DotArt
    SIZE = 7          # the identicon's grid
    MAX = 9           # the largest sprite a theme may give
    EYE = "o"         # the palette character for a face's eyes
    BODY = "#"
    EDGE = "+"        # lit cells on the shape's outline, a lighter body colour
    EYE_ROW = 2
    EYE_COLS = [2, 4].freeze
    # Status labels as the theme's `status:` table and `art.status` spell them.
    LABELS = { "working" => "Working", "idle" => "Idle", "error" => "Error", "stale" => "Stale", "ended" => "Ended" }.freeze

    module_function

    # Rows -> a grid of palette characters (nil for unlit). Raises
    # ArgumentError, with the reason, for anything that isn't a rectangle of
    # strings up to MAX x MAX.
    def parse_rows(rows)
      raise ArgumentError, "must be a list of strings" unless rows.is_a?(Array) && !rows.empty? && rows.all?(String)
      w = rows.first.length
      raise ArgumentError, "must be strings of equal length" unless rows.all? { |r| r.length == w }
      raise ArgumentError, "may be at most #{MAX} x #{MAX}" if rows.size > MAX || w > MAX || w.zero?
      rows.map { |r| r.each_char.map { |ch| ch == "." ? nil : ch } }
    end

    # The sprite for +bot+: the theme's own for that bot (by name, any
    # case), else the theme's for its +status+, else the generated identicon
    # with +body+ as its colour (a hex or theme colour name).
    def sprite_for(art, bot, status, body: nil)
      art ||= {}
      own = (art["bots"] || {}).find { |name, sp| name.to_s.downcase == bot.to_s.downcase && sp["rows"] }
      return own.last if own
      st = (art["status"] || {})[LABELS[status.to_s] || status.to_s]
      return st if st && st["rows"]
      identicon(bot, body: body)
    end

    # A 7 x 7 robot face for +name+, the same every time: the left four
    # columns come from the first bytes of the name's SHA-256, mirrored onto
    # the right. The top row is head room, the two eyes are always lit, and
    # lit cells on the shape's edge get a lighter colour for depth.
    def identicon(name, body: nil, eye: "pink")
      body ||= "dot_lit"
      bits = Digest::SHA256.digest(name.to_s.downcase.strip).bytes.first(4).map { |b| b.to_s(2).rjust(8, "0") }.join
      lit = Array.new(SIZE) { Array.new(SIZE, false) }
      i = 0
      (1...SIZE).each do |r|
        (0..SIZE / 2).each do |c|
          on = bits[i] == "1"
          i += 1
          lit[r][c] = on
          lit[r][SIZE - 1 - c] = on
        end
      end
      EYE_COLS.each { |c| lit[EYE_ROW][c] = true }
      rows = lit.each_with_index.map do |row, r|
        row.each_with_index.map do |on, c|
          next "." unless on
          next EYE if r == EYE_ROW && EYE_COLS.include?(c)
          edge?(lit, r, c) ? EDGE : BODY
        end.join
      end
      { "rows" => rows, "palette" => { BODY => body, EDGE => lighter(body), EYE => eye } }
    end

    # A lit cell with an unlit (or no) neighbour above, below, left or right.
    def edge?(lit, r, c)
      [[r - 1, c], [r + 1, c], [r, c - 1], [r, c + 1]].any? do |rr, cc|
        rr.negative? || cc.negative? || rr >= SIZE || cc >= SIZE || !lit[rr][cc]
      end
    end

    # A hex moved a quarter of the way to white; a colour name is given
    # back as it is (the widget tints it when it resolves the name).
    def lighter(color, t = 0.25)
      return color unless color.to_s.match?(/\A#\h{6}\z/)
      rgb = [color[1, 2], color[3, 2], color[5, 2]].map { |p| p.to_i(16) }
      format("#%02X%02X%02X", *rgb.map { |v| (v + (255 - v) * t).round })
    end
  end
end
