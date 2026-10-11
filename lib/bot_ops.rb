# frozen_string_literal: true

# Bot Ops Blue - library loader.
#
# Everything here is plain Ruby with no GUI dependency, so tests and previews
# run anywhere. The window itself lives in ext/bot_ops_native (Rust, egui) and
# is driven by BotOps::NativeHost.
require "bot_ops/theme"
require "bot_ops/layout"
require "bot_ops/history"
require "bot_ops/store"
require "bot_ops/probe"
require "bot_ops/collector"
require "bot_ops/cloud_feed"
require "bot_ops/comms"
require "bot_ops/canvas"
require "bot_ops/overlay"
require "bot_ops/widgets"
require "bot_ops/panels"
require "bot_ops/scene"
require "bot_ops/display"
require "bot_ops/native_host"

module BotOps
  VERSION = "0.3.0"
end
