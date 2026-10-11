# frozen_string_literal: true

require "open3"

module BotOps
  # Chooses which monitor the window opens on.
  #
  #   BOT_OPS_DISPLAY=external   first non-main monitor (default); refuses to
  #                              open on the main monitor if none is connected
  #   BOT_OPS_DISPLAY=main       the main monitor
  #   BOT_OPS_DISPLAY=2          monitor number 2, in macOS's NSScreen order
  #   BOT_OPS_POSITION=x,y       exact top-left corner in screen points
  #
  # Screen discovery is macOS only; elsewhere (or when it fails) placement is
  # left to the OS unless BOT_OPS_POSITION is set. Positions are in points,
  # top-left origin, relative to the main monitor's top-left corner.
  module Display
    Screen = Struct.new(:name, :left, :top, :width, :height)

    # JXA snippet printing one "name|x|y|w|h" line per screen (Cocoa frames:
    # bottom-left origin, main screen first).
    LIST_SCREENS_JXA = <<~JS
      ObjC.import("AppKit");
      var s = $.NSScreen.screens, out = [];
      for (var i = 0; i < s.count; i++) {
        var sc = s.objectAtIndex(i), f = sc.frame;
        out.push([ObjC.unwrap(sc.localizedName), f.origin.x, f.origin.y, f.size.width, f.size.height].join("|"));
      }
      out.join("\\n");
    JS

    module_function

    # Returns "left,top" for the native window, "" to let the OS decide, or
    # nil when the external monitor was asked for (the default) but macOS
    # reports none, so the caller can refuse rather than cover the main one.
    def position(width, height, env: ENV, screens: nil)
      if (explicit = env["BOT_OPS_POSITION"]) && explicit =~ /\A\s*-?\d+\s*,\s*-?\d+\s*\z/
        return explicit.delete(" ")
      end
      screens ||= self.screens
      choice = env.fetch("BOT_OPS_DISPLAY", "external")
      screen = pick(screens, choice)
      return center(screen, width, height).join(",") if screen
      external?(choice) && screens.size == 1 ? nil : ""
    end

    def external?(choice)
      ["", "external"].include?(choice.to_s.strip.downcase)
    end

    def pick(screens, choice)
      case choice.to_s.strip.downcase
      when "", "external" then screens[1]
      when "main" then nil
      when /\A\d+\z/ then screens[choice.to_i - 1] if choice.to_i >= 1
      end
    end

    # Top-left corner that centers a width x height window on +screen+,
    # pinned to the screen's top-left when the window is larger.
    def center(screen, width, height)
      [screen.left + [(screen.width - width) / 2, 0].max,
       screen.top + [(screen.height - height) / 2, 0].max]
    end

    def screens
      return [] unless RUBY_PLATFORM =~ /darwin/
      out, status = Open3.capture2("osascript", "-l", "JavaScript", "-e", LIST_SCREENS_JXA)
      status.success? ? parse_cocoa(out) : []
    rescue SystemCallError
      []
    end

    # Converts Cocoa frames (bottom-left origin, y up) to top-left origin.
    def parse_cocoa(text)
      rows = text.lines.map { |l| l.chomp.split("|") }.select { |r| r.size == 5 }
      return [] if rows.empty?
      main_h = rows.first[4].to_f
      rows.map do |name, x, y, w, h|
        x, y, w, h = [x, y, w, h].map { |v| v.to_f.round }
        Screen.new(name, x, (main_h - (y + h)).round, w, h)
      end
    end
  end
end
