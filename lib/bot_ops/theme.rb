# frozen_string_literal: true

module BotOps
  # Colour palette and typography for the hub. Hex strings are accepted
  # directly by Shoes 3 for stroke/fill; use Theme.rgba for translucent colours.
  module Theme
    BG      = "#050B14"
    PANEL   = "#07131F"
    PANEL2  = "#0A1A2A"
    TRACK   = "#0E2234"
    LINE    = "#113347"

    CYAN    = "#00E5FF"
    TEAL    = "#00FFB2"
    BLUE    = "#3B82F6"
    PURPLE  = "#A855F7"
    PINK    = "#FF4FD8"
    YELLOW  = "#F5C518"
    ORANGE  = "#FF8A3D"
    RED     = "#FF3B5C"
    GREEN   = "#22E07A"

    TEXT    = "#DCE8F0"
    MUTED   = "#7C94A6"
    DIM     = "#3C5566"

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
