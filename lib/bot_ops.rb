# frozen_string_literal: true

# Claude Bot Ops Hub - library loader.
# Toolkit-agnostic pieces: theme, layout, store, comms.
# Shoes-specific pieces:   widgets, panels, hub.
require "bot_ops/theme"
require "bot_ops/layout"
require "bot_ops/store"
require "bot_ops/comms"
require "bot_ops/widgets"
require "bot_ops/panels"
require "bot_ops/hub"

module BotOps
  VERSION = "0.1.0"
end
