# frozen_string_literal: true

module BotOps
  # Colour palette and typography. Colours are "#RRGGBB" hex strings; use
  # Theme.rgba for translucent ones.
  module Theme
    # Accents are sampled from assets/bot-blue.png (the logo): the royal
    # armour blues, the glowing cyan eyes, ice-white plating and the gold
    # crest. Backgrounds keep the original dark navy.
    BG      = "#040A17"
    BG_TOP  = "#071330"   # the background brightens toward the top left
    PANEL   = "#081429"   # panel fill, bottom of its gradient
    PANEL_TOP = "#0C1D3C" # panel fill, top of its gradient
    PANEL2  = "#0C1B36"   # cards inside a panel
    OVERLAY_BG = "#07131F" # the details box: dark, so its text stands out
    CARD_TOP = "#10244A"
    TRACK   = "#132A52"   # gauge and bar tracks
    LINE    = "#16305E"
    BORDER  = "#2457E6"   # panel and card outlines

    EDGE      = "#0B3BF0" # deep electric royal armour: frame glow
    EDGE_SOFT = "#0A2CB8" # the same, darker, for boxes inside a frame
    BOLT      = "#3D82FF" # bright electric blue: the core of every frame line
    SPARK     = "#C8F6FF" # white-hot eye core: hairlines, corners and sparks

    CYAN    = "#30C8FC"   # eye glow: the primary accent
    TEAL    = "#4D9DFF"   # clear azure: the secondary accent
    BLUE    = "#2F6BFF"   # electric royal blue armour
    PURPLE  = "#8C8CFF"   # blue-violet shadow plating
    PINK    = "#B7FCFD"   # white-hot eye core
    YELLOW  = "#F0B23C"   # gold crest
    ORANGE  = "#C9852E"   # darker crest gold
    RED     = "#FF4D6A"
    GREEN   = "#2FDC8A"   # mint (busy, online, healthy)
    SLATE   = "#6F82B8"   # idle and ended

    TEXT    = "#E8F0FB"   # ice-white plating
    MUTED   = "#8EA2CF"
    SUBTLE  = "#5E86D6"   # secondary text on cards (project · client)
    DIM     = "#3D5085"

    FAMILY  = "Sans"
    MONO    = "Monospace"

    # "#RRGGBB" -> [r, g, b] integers
    def self.hex_rgb(hex)
      h = hex.to_s.delete("#")
      [h[0, 2], h[2, 2], h[4, 2]].map { |p| p.to_i(16) }
    end

    STATUS_COLORS = {
      "Busy"      => GREEN,
      "Needs you" => YELLOW,
      "Ended"     => SLATE,
      "Running"   => TEAL,
      "Completed" => TEAL,
      "Pending"   => YELLOW,
      "Idle"      => SLATE,
      "Failed"    => RED,
      "Error"     => RED,
      "Paused"    => ORANGE
    }.freeze

    PRIORITY_COLORS = {
      "High"   => RED,
      "Medium" => YELLOW,
      "Low"    => BLUE
    }.freeze

    LEVEL_COLORS = {
      "INFO"  => CYAN,
      "WARN"  => YELLOW,
      "ERROR" => RED
    }.freeze

    def self.status_color(status)
      STATUS_COLORS[status] || MUTED
    end

    def self.priority_color(priority)
      PRIORITY_COLORS[priority] || MUTED
    end

    def self.level_color(level)
      LEVEL_COLORS[level] || MUTED
    end
  end
end
