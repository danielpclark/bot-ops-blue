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

    # Live Claude Code activity. Probes this machine every POLL_S seconds on a
    # background thread, and, when BOT_OPS_LISTEN is set, also accepts
    # snapshots from bin/bot-ops-agent on other machines. Each snapshot becomes
    # one { type: "snapshot" } event for Store#apply.
    class ClaudeChannel < Channel
      POLL_S = 2

      attr_reader :collector, :collector_error

      def initialize(probe: Probe.new, listen: ENV["BOT_OPS_LISTEN"], token: ENV["BOT_OPS_TOKEN"])
        super()
        @probe = probe
        @listen = listen
        @token = token
      end

      def start(_store)
        start_collector if @listen && !@listen.empty?
        push(type: "collector", status: collector_status)
        @thread = Thread.new do
          loop do
            begin
              push(type: "snapshot", snapshot: @probe.snapshot, local: true)
            rescue StandardError => e
              push(type: "probe.error", message: "#{e.class}: #{e.message}")
            end
            sleep POLL_S
          end
        end
      end

      def stop
        @thread&.kill
        @collector&.stop
      end

      def name
        "Claude Code (local probe#{@collector ? ' + collector' : ''})"
      end

      def collector_status
        return "Collector failed: #{@collector_error}" if @collector_error
        return "Collecting on #{@collector.address}" if @collector
        "This machine only"
      end

      private

      def start_collector
        @collector = Collector.new(@listen, @token) { |snap| push(type: "snapshot", snapshot: snap, local: false) }.start
      rescue StandardError => e
        @collector = nil
        @collector_error = e.message
      end
    end
  end
end
