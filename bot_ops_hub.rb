# Bot Ops Blue
#
# A borderless desktop operations dashboard for a fleet of bots,
# written for Shoes 3.3 "Walkabout" (https://github.com/shoes/shoes3).
#
#   shoes bot_ops_hub.rb
#
# The window has no OS title bar: drag the header to move it, use the three
# glyphs in the top-right corner to restore the title bar, go fullscreen, or
# quit. Live data currently comes from BotOps::Comms::SimulatedChannel; see
# lib/bot_ops/comms.rb for how to plug in a real transport.

APP_ROOT = File.expand_path(File.dirname(__FILE__)) unless defined?(APP_ROOT)
lib = File.join(APP_ROOT, "lib")
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "bot_ops"

Shoes.app(title: "Bot Ops Blue",
          width: BotOps::Layout::WIDTH,
          height: BotOps::Layout::HEIGHT,
          resizable: false,
          decorated: false) do
  extend BotOps::Widgets
  extend BotOps::Panels
  extend BotOps::Hub
  boot
end
