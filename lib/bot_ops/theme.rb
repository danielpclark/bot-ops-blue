# frozen_string_literal: true

module BotOps
  # Colour palette and typography for the hub. Hex strings are accepted
  # directly by Shoes 3 for stroke/fill; use Theme.rgba for translucent colours.
  module Theme
    # Accents are sampled from assets/bot-blue.png (the logo): the royal
    # armour blues, the glowing cyan eyes, ice-white plating and the gold
    # crest. Backgrounds keep the original dark navy.
    BG      = "#050B14"
    PANEL   = "#07131F"
    PANEL2  = "#0A1A2A"
    TRACK   = "#0E2234"
    LINE    = "#113347"

    EDGE      = "#0B3BF0" # deep electric royal armour: every frame outline
    EDGE_SOFT = "#0A2CB8" # the same, darker, for boxes inside a frame

    CYAN    = "#30C8FC"   # eye glow: the primary accent
    TEAL    = "#7FA8FF"   # periwinkle armour highlight: the secondary accent
    BLUE    = "#2F6BFF"   # electric royal blue armour
    PURPLE  = "#8C8CFF"   # blue-violet shadow plating
    PINK    = "#B7FCFD"   # white-hot eye core
    YELLOW  = "#F0B23C"   # gold crest
    ORANGE  = "#C9852E"   # darker crest gold
    RED     = "#FF4D6A"
    GREEN   = "#3CF0B4"

    TEXT    = "#E8F0FB"   # ice-white plating
    MUTED   = "#8EA0D6"
    DIM     = "#3A4C86"

    FAMILY  = "Sans"
    MONO    = "Monospace"

    # "#RRGGBB" -> [r, g, b] integers
    def self.hex_rgb(hex)
      h = hex.to_s.delete("#")
      [h[0, 2], h[2, 2], h[4, 2]].map { |p| p.to_i(16) }
    end

    STATUS_COLORS = {
      "Busy"      => CYAN,
      "Needs you" => YELLOW,
      "Ended"     => DIM,
      "Running"   => TEAL,
      "Completed" => TEAL,
      "Pending"   => YELLOW,
      "Idle"      => DIM,
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
