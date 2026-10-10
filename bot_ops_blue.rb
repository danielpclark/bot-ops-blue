# Bot Ops Blue
#
# A borderless desktop operations dashboard for a fleet of bots. Ruby owns
# the data and layout; a small Rust extension (egui/eframe, bound with Rutie)
# owns the window and rendering.
#
#   bundle exec rake setup   # bundle install + cargo build (needs Rust)
#   bundle exec rake run
#
# The window has no OS title bar: drag the header to move it, use the three
# glyphs in the top-right corner to restore the title bar, go fullscreen, or
# quit. Data is live: BotOps::Probe reads this machine's Claude Code sessions,
# and bin/bot-ops-agent reports other machines to the collector (see README).

APP_ROOT = File.expand_path(File.dirname(__FILE__)) unless defined?(APP_ROOT)
lib = File.join(APP_ROOT, "lib")
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "bot_ops"

BotOps::NativeHost.new.launch
