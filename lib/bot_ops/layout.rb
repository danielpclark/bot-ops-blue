# frozen_string_literal: true

module BotOps
  # Pixel geometry of the dashboard, laid out for the minimum (design) size
  # WIDTH x HEIGHT. A larger window stretches the content area: Layout.fit maps
  # a design rect onto the actual size so panels grow to fill it.
  module Layout
    WIDTH  = 1536
    HEIGHT = 1024

    HEADER_H   = 86
    SIDEBAR_X  = 12
    SIDEBAR_W  = 76
    CONTENT_X  = 100
    CONTENT_Y  = 97
    CONTENT_W  = WIDTH - CONTENT_X - 20
    CONTENT_H  = HEIGHT - CONTENT_Y - 14
    GAP        = 12

    # Row 1
    ROW1_Y = CONTENT_Y
    ROW1_H = 400
    FLEET     = [CONTENT_X,  ROW1_Y, 392, ROW1_H]
    ACTIVITY  = [504,        ROW1_Y, 592, ROW1_H]
    WORKFLOWS = [1108,       ROW1_Y, 408, ROW1_H]

    # Row 2
    ROW2_Y = ROW1_Y + ROW1_H + GAP
    ROW2_H = 272
    QUEUE    = [CONTENT_X, ROW2_Y, 466, ROW2_H]
    PIPELINE = [578,       ROW2_Y, 518, ROW2_H]
    HEALTH   = [1108,      ROW2_Y, 408, ROW2_H]

    # Row 3
    ROW3_Y = ROW2_Y + ROW2_H + GAP
    ROW3_H = HEIGHT - ROW3_Y - 14
    RECENT  = [CONTENT_X, ROW3_Y, 392, ROW3_H]
    AGENT   = [504,       ROW3_Y, 372, ROW3_H]
    LOGS    = [888,       ROW3_Y, 332, ROW3_H]
    REPORTS = [1232,      ROW3_Y, 284, ROW3_H]

    PANEL_TITLE_H = 36

    def self.content_w(width)
      width - CONTENT_X - 20
    end

    def self.content_h(height)
      height - CONTENT_Y - 14
    end

    # Maps a design rect [x, y, w, h] inside the content area onto a window of
    # +width+ x +height+. Edges are mapped, not sizes, so neighbouring panels
    # keep sharing the same gap and the outer ones stay flush with the edges.
    def self.fit(rect, width, height)
      x, y, w, h = rect
      kx = content_w(width).to_f / CONTENT_W
      ky = content_h(height).to_f / CONTENT_H
      left   = CONTENT_X + ((x - CONTENT_X) * kx).round
      right  = CONTENT_X + ((x + w - CONTENT_X) * kx).round
      top    = CONTENT_Y + ((y - CONTENT_Y) * ky).round
      bottom = CONTENT_Y + ((y + h - CONTENT_Y) * ky).round
      [left, top, right - left, bottom - top]
    end

    NAV = [
      [:overview,  "Overview",  "⌂"],
      [:sessions,  "Sessions",  "◉"],
      [:projects,  "Projects",  "⬡"],
      [:tools,     "Tools",     "☰"],
      [:usage,     "Usage",     "▤"],
      [:logs,      "Logs",      "≡"],
      [:machines,  "Machines",  "⌁"],
      [:settings,  "Settings",  "⚙"]
    ].freeze
  end
end
