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
      @fullscreen = false
      @last_tick = Time.now
    end

    LOCK_FILE = File.join(Dir.home, ".config", "bot-ops-blue", "dashboard.lock")

    # Only one dashboard at a time: an exclusive lock held for the life of the
    # process (the OS drops it on exit, crash or kill -9). Returns the lock
    # file to keep open, or nil when another dashboard holds it.
    def self.single_instance_lock(path = LOCK_FILE)
      require "fileutils"
      FileUtils.mkdir_p(File.dirname(path))
      f = File.open(path, File::RDWR | File::CREAT, 0o600)
      unless f.flock(File::LOCK_EX | File::LOCK_NB)
        f.close
        return nil
      end
      f.truncate(0)
      f.write("#{Process.pid}\n")
      f.flush
      f
    end

    def self.native_built?
      File.exist?(NATIVE_LIB)
    end

    def launch
      unless self.class.native_built?
        abort "Native extension not built (#{NATIVE_LIB}). Run: bundle exec rake setup"
      end
      @lock = self.class.single_instance_lock
      unless @lock
        other = File.read(LOCK_FILE).strip rescue "?"
        abort "Bot Ops Blue is already running (pid #{other}); not opening a second window."
      end
      require NATIVE_LIB
      @channel.start(@store)
      position = Display.position(Layout::WIDTH, Layout::HEIGHT)
      if position.nil?
        abort "No external monitor detected. Connect one, or run with BOT_OPS_DISPLAY=main to use the main screen."
      end
      Native.run(self, Layout::WIDTH, Layout::HEIGHT, "Bot Ops Blue", position)
    rescue Interrupt, SignalException
      nil # Ctrl+C or a TERM: the native side closed the window; just leave quietly
    ensure
      @channel.stop
    end

    # ---- called from Rust --------------------------------------------------
    #
    # Rust only learns *that* one of these raised, so each logs the exception
    # before letting it propagate. A Ctrl+C or TERM that lands while Ruby is
    # in one of them would be swallowed the same way, so it becomes a quit
    # instead: poll and hit answer "quit" (now or at the next poll) and the
    # native side closes the window.

    QUIT = "quit"

    def self.logged(*names)
      names.each do |name|
        original = instance_method(name)
        define_method(name) do |*args|
          return QUIT if @quit && (name == :poll || name == :hit)
          original.bind_call(self, *args)
        rescue Interrupt, SignalException
          @quit = true
          name == :poll || name == :hit ? QUIT : nil
        rescue Exception => e # rubocop:disable Lint/RescueException
          warn "bot_ops: #{name} raised #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(8).join("\n  ")}"
          raise
        end
      end
    end

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

    # The native side owns window state and toggles against it; it reports
    # fullscreen changes back so the header can show the right control.
    def fullscreen_changed(on)
      @fullscreen = on.to_i == 1
      @dirty = true
      nil
    end

    def fullscreen?
      @fullscreen
    end

    def minimize
      @pending = "minimize"
    end

    # Mouse wheel / trackpad lines from the native side.
    def scroll(lines)
      @dirty = true if @scene.scroll(lines.to_i)
      nil
    end

    # A key the native side offers to Ruby first; "handled" when it was used
    # (27 = Esc closes an open overlay before Esc leaves fullscreen).
    def key(code)
      code.to_i == 27 && @scene.escape ? "handled" : ""
    end

    # The native side opens it in the default browser (claude.ai links only).
    def open_url(url)
      @pending = "open:#{url}"
    end

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

    logged :poll, :hit, :resize, :fullscreen_changed, :scroll, :key
  end
end
