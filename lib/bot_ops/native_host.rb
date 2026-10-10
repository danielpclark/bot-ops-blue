# frozen_string_literal: true

module BotOps
  # Host for the Rust window (ext/bot_ops_native). The native side calls
  # #poll on every repaint and #hit when a clickable region is pressed; this
  # object answers with a frame (JSON) and window commands.
  class NativeHost
    NATIVE_DIR = File.expand_path("native", __dir__)
    EXT = RUBY_PLATFORM =~ /darwin/ ? "bundle" : "so"
    NATIVE_LIB = File.join(NATIVE_DIR, "bot_ops_native.#{EXT}")

    attr_reader :store, :channel, :scene

    def initialize(store: nil, channel: nil)
      @store = store || Store.new
      @channel = channel || Comms::ClaudeChannel.new
      @scene = Scene.new(@store, self)
      @canvas = nil
      @dirty = true
      @pending = nil
      @last_tick = Time.now
    end

    def self.native_built?
      File.exist?(NATIVE_LIB)
    end

    def launch
      unless self.class.native_built?
        abort "Native extension not built (#{NATIVE_LIB}). Run: bundle exec rake setup"
      end
      require NATIVE_LIB
      @channel.start(@store)
      position = Display.position(Layout::WIDTH, Layout::HEIGHT)
      if position.nil?
        abort "No external monitor detected. Connect one, or run with BOT_OPS_DISPLAY=main to use the main screen."
      end
      Native.run(self, Layout::WIDTH, Layout::HEIGHT, "Bot Ops Blue", position)
      @channel.stop
    end

    # ---- called from Rust --------------------------------------------------

    # Returns a JSON frame when something changed since the last poll, else "".
    # Only strings and integers cross the Rutie boundary (see README).
    def poll
      # New data is applied as soon as it arrives (the probe reports every
      # second); the periodic tick only keeps the clock and "Xm ago" current.
      events = @channel.poll(@store)
      unless events.empty?
        @store.apply_all(events)
        @dirty = true
      end
      if Time.now - @last_tick >= Scene::REFRESH_SECONDS
        @last_tick = Time.now
        @dirty = true
      end
      return "" unless @dirty
      @dirty = false
      @canvas = @scene.build
      @canvas.to_json(drag: [0, 0, @scene.width, Layout::HEADER_H])
    end

    # The window's size in points changed (fullscreen, resize); lay out again.
    def resize(width, height)
      return if [width, height] == [@scene.width, @scene.height]
      @scene.resize(width, height)
      @dirty = true
    end

    # Runs the handler of hit region +id+; returns a window command or "".
    def hit(id)
      h = @canvas && id >= 0 && @canvas.hits[id]
      h.handler.call if h
      cmd = @pending || ""
      @pending = nil
      cmd
    end

    # ---- host protocol used by Scene ----------------------------------------

    def invalidate
      @dirty = true
    end

    # The native side owns window state and toggles against it.
    def toggle_decorations
      @pending = "decorations:toggle"
    end

    def toggle_fullscreen
      @pending = "fullscreen:toggle"
    end

    def quit
      @pending = "quit"
    end

    def toolkit_name
      "egui/eframe (Rust) via Rutie"
    end

    def channel_name
      @channel.name
    end
  end
end
