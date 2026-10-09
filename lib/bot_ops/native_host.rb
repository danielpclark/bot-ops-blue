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
      @channel = channel || Comms::SimulatedChannel.new
      @scene = Scene.new(@store, self)
      @canvas = nil
      @dirty = true
      @decorated = false
      @fullscreen = false
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
      Native.run(self, Layout::WIDTH, Layout::HEIGHT, "Bot Ops Blue")
      @channel.stop
    end

    # ---- called from Rust --------------------------------------------------

    # Returns a JSON frame when something changed since the last poll, else "".
    # Only strings and integers cross the Rutie boundary (see README).
    def poll
      if Time.now - @last_tick >= Scene::REFRESH_SECONDS
        @last_tick = Time.now
        @store.apply_all(@channel.poll(@store))
        @dirty = true
      end
      return "" unless @dirty
      @dirty = false
      @canvas = @scene.build
      @canvas.to_json(drag: [0, 0, Layout::WIDTH, Layout::HEADER_H])
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

    def toggle_decorations
      @decorated = !@decorated
      @pending = "decorations:#{@decorated ? 'on' : 'off'}"
    end

    def toggle_fullscreen
      @fullscreen = !@fullscreen
      @pending = "fullscreen:#{@fullscreen ? 'on' : 'off'}"
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
