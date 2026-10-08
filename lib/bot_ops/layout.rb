# frozen_string_literal: true

module BotOps
  # Pixel geometry of the dashboard. Everything is absolutely positioned so the
  # borderless window renders identically on every platform Shoes runs on.
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

    NAV = [
      [:overview,  "Overview",  "⌂"],
      [:bots,      "Bots",      "◉"],
      [:workflows, "Workflows", "⬡"],
      [:queue,     "Queue",     "☰"],
      [:data,      "Data",      "▤"],
      [:logs,      "Logs",      "≡"],
      [:analytics, "Analytics", "⌁"],
      [:settings,  "Settings",  "⚙"]
    ].freeze
  end
end
