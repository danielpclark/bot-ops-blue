# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "bot_ops"

# A snapshot shaped like Probe#snapshot, for tests that need a populated store.
module Fixtures
  module_function

  def snapshot(host: "laptop", now: Time.now.to_f)
    hour = (now.to_i / 3600) * 3600
    {
      "host" => host, "at" => now,
      "machine" => { "os" => "darwin", "cpus" => 8, "load" => 2.0, "mem_pct" => 61, "disk_pct" => 40, "uptime_s" => 90_000 },
      "sessions" => [
        { "id" => "s-busy", "pid" => 101, "name" => "api-fix", "cwd" => "/src/api", "kind" => "interactive",
          "entrypoint" => "cli", "status" => "busy", "started_at" => now - 1800, "status_at" => now - 5,
          "version" => "2.1.0", "model" => "claude-opus-5-5", "title" => "Fix flaky login test", "branch" => "main",
          "tokens" => { "in" => 10, "out" => 4200, "cache_read" => 90_000, "cache_write" => 3000 }, "context" => 52_000,
          "tool_calls" => 14, "errors" => 1, "prompts" => 3, "last_at" => now - 5,
          "last_tool" => { "name" => "Bash", "detail" => "bundle exec rake test", "at" => now - 5 } },
        { "id" => "s-idle", "pid" => 102, "name" => "docs", "cwd" => "/src/site", "kind" => "interactive",
          "entrypoint" => "claude-vscode", "status" => "idle", "started_at" => now - 7200, "status_at" => now - 600,
          "model" => "claude-sonnet-5-5", "tool_calls" => 2, "errors" => 0, "prompts" => 1, "last_at" => now - 600 }
      ],
      "events" => [
        { "at" => now - 5, "sid" => "s-busy", "project" => "api", "kind" => "tool", "title" => "Bash", "detail" => "bundle exec rake test" },
        { "at" => now - 30, "sid" => "s-busy", "project" => "api", "kind" => "error", "title" => "tool error", "detail" => "exit 1" },
        { "at" => now - 60, "sid" => "s-busy", "project" => "api", "kind" => "tool", "title" => "Edit", "detail" => "~/src/api/login.rb" },
        { "at" => now - 90, "sid" => "s-busy", "project" => "api", "kind" => "prompt", "title" => "prompt", "detail" => "fix the flaky login test" }
      ],
      "hourly" => [[hour - 3600, 1200, 5, 1, 0], [hour, 3000, 9, 2, 1]],
      "projects" => [{ "cwd" => "/src/api", "out_tokens" => 4200, "tool_calls" => 14, "prompts" => 3, "sessions" => 1,
                       "last_at" => now - 5, "branch" => "main" }]
    }
  end

  def store(**opts)
    BotOps::Store.new.apply(type: "snapshot", snapshot: snapshot(**opts), local: true)
  end
end
