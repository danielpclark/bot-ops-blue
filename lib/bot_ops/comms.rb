# frozen_string_literal: true

require "thread"

module BotOps
  module Comms
    # Base class for anything that feeds events into the hub.
    #
    # Shoes (like most GUI toolkits) wants all drawing on its main thread, so
    # channels never touch the store themselves. They enqueue event hashes and
    # the hub drains them with #poll from a Shoes timer.
    #
    # To add real comms later, subclass Channel, start a background thread (or
    # socket reader) in #start, and call #push(event) for each message:
    #
    #   class SocketChannel < BotOps::Comms::Channel
    #     def start(store)
    #       @thread = Thread.new do
    #         TCPSocket.open(host, port) { |s| s.each_line { |l| push(JSON.parse(l)) } }
    #       end
    #     end
    #   end
    class Channel
      def initialize
        @queue = Queue.new
      end

      def start(_store); end

      def stop; end

      def push(event)
        @queue << event
      end

      def poll(_store)
        out = []
        out << @queue.pop(true) until @queue.empty?
        out
      rescue ThreadError
        out
      end

      def name
        self.class.name.split("::").last
      end
    end

    # Fans events out from several channels.
    class Multiplexer < Channel
      def initialize(*channels)
        super()
        @channels = channels
      end

      def start(store)
        @channels.each { |c| c.start(store) }
      end

      def stop
        @channels.each(&:stop)
      end

      def poll(store)
        @channels.flat_map { |c| c.poll(store) } + super(store)
      end
    end

    # A deterministic-ish simulator so the hub looks alive before any real
    # transport exists. It reads the store to decide what to nudge next.
    class SimulatedChannel < Channel
      LOG_POOL = [
        ["INFO", "Generated video clip #%d/15"],
        ["INFO", "Fetched 42 new leads from CRM"],
        ["INFO", "Scheduled post for 19:00"],
        ["WARN", "Retrying webhook delivery (2/3)"],
        ["INFO", "Cache warmed for dashboard metrics"],
        ["INFO", "Resolved ticket #%d"],
        ["WARN", "Rate limit approaching (API)"],
        ["INFO", "Transcoded media with ffmpeg (AV1)"],
        ["ERROR", "Upload failed: token expired (auto-renewing)"],
        ["INFO", "Health check passed (482ms)"]
      ].freeze

      def initialize(seed = 42)
        super()
        @rng = Random.new(seed)
        @ticks = 0
      end

      def poll(store)
        @ticks += 1
        events = [{ type: "tick", seconds: 2 }]

        store.activity.each do |a|
          next unless a.status == "Running"
          step = @rng.rand(0..4)
          events << { type: "progress", bot_id: a.bot_id, progress: a.progress + step }
        end

        if (@ticks % 3).zero?
          level, tmpl = LOG_POOL[@rng.rand(LOG_POOL.size)]
          events << { type: "log", level: level, message: format(tmpl, @rng.rand(1..9999)) }
        end

        if (@ticks % 2).zero?
          h = store.health
          events << {
            type: "health",
            cpu: clamp(h[:cpu] + @rng.rand(-4..4), 5, 95),
            memory: clamp(h[:memory] + @rng.rand(-2..2), 10, 95),
            network: clamp(h[:network] + @rng.rand(-3..5), 1, 90),
            storage: h[:storage],
            response_ms: clamp(h[:response_ms] + @rng.rand(-30..30), 120, 900)
          }
        end

        if (@ticks % 15).zero?
          last = store.series.map { |s| [s[:key], (s[:values].last + @rng.rand(-5..6)).clamp(0, 60)] }.to_h
          hh, mm = store.series_labels.last.split(":").map(&:to_i)
          label = format("%02d:%02d", (hh + 1) % 24, mm)
          events << { type: "series.push", label: label, values: last }
        end

        if (@ticks % 20).zero?
          p = store.pipeline_stages.map { |s| [s[:key], clamp(s[:count] + @rng.rand(-3..3), 0, 99)] }.to_h
          events << p.merge(type: "pipeline")
        end

        if (@ticks % 10).zero?
          d = store.agent_detail
          events << { type: "agent.detail", progress: [d[:progress] + @rng.rand(1..3), 100].min }
        end

        # Restart finished activities so the "Live" tab never empties.
        store.activity.each do |a|
          next unless a.status == "Completed" && @rng.rand < 0.08
          bot = store.bot(a.bot_id)
          events << { type: "event", bot_id: a.bot_id, message: "Finished #{a.task.sub(/\A\w+ing /, "").downcase}" }
          events << { type: "activity.status", bot_id: a.bot_id, status: "Running" }
          events << { type: "progress", bot_id: a.bot_id, progress: 0 }
          events << { type: "log", level: "INFO", message: "#{bot ? bot.name : a.bot_id} picked up next task" }
        end

        events + super(store)
      end

      private

      def clamp(v, lo, hi)
        [[v, lo].max, hi].min
      end
    end
  end
end
