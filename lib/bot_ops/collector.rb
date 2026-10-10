# frozen_string_literal: true

require "socket"
require "json"
require "openssl"

module BotOps
  # Receives snapshots from bin/bot-ops-agent running on other machines.
  #
  #   POST /v1/snapshot   Authorization: Bearer <token>   body: Probe#snapshot JSON
  #   GET  /v1/health     -> 200 "ok"
  #
  # Off unless BOT_OPS_LISTEN is set (e.g. "0.0.0.0:47800" for the LAN, or a
  # Tailscale address). A token is always required; it is the only thing
  # standing between the port and anyone who can reach it.
  class Collector
    MAX_BODY = 4 * 1024 * 1024

    attr_reader :address

    def initialize(listen, token, &on_snapshot)
      host, port = listen.to_s.include?(":") ? listen.split(":", 2) : ["127.0.0.1", listen]
      @host = host.empty? ? "0.0.0.0" : host
      @port = Integer(port)
      @token = token.to_s
      raise ArgumentError, "BOT_OPS_TOKEN must be set (16+ characters) to accept remote snapshots" if @token.length < 16
      @on_snapshot = on_snapshot
    end

    def start
      @server = TCPServer.new(@host, @port)
      @address = "#{@host}:#{@server.addr[1]}"
      @thread = Thread.new { accept_loop }
      self
    end

    def stop
      @server&.close
      @thread&.kill
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        Thread.new(client) { |c| handle(c) }
      end
    rescue IOError, Errno::EBADF
      nil # server closed
    end

    def handle(client)
      client.wait_readable(5) or return
      request = client.gets.to_s
      method, path, = request.split(" ")
      headers = {}
      while (line = client.gets) && line != "\r\n"
        k, v = line.split(":", 2)
        headers[k.strip.downcase] = v.to_s.strip if v
      end
      status, body = route(method, path, headers, client)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    rescue StandardError
      nil
    ensure
      client.close
    end

    def route(method, path, headers, client)
      return ["200 OK", "ok"] if method == "GET" && path == "/v1/health"
      return ["404 Not Found", "not found"] unless method == "POST" && path == "/v1/snapshot"
      return ["401 Unauthorized", "bad token"] unless authorized?(headers["authorization"])
      length = headers["content-length"].to_i
      return ["413 Payload Too Large", "too large"] if length <= 0 || length > MAX_BODY
      snapshot = JSON.parse(client.read(length))
      return ["422 Unprocessable Entity", "no host"] unless snapshot.is_a?(Hash) && snapshot["host"].is_a?(String)
      @on_snapshot.call(snapshot)
      ["204 No Content", ""]
    rescue JSON::ParserError
      ["400 Bad Request", "bad json"]
    end

    def authorized?(header)
      given = header.to_s.delete_prefix("Bearer ").strip
      given.bytesize == @token.bytesize && OpenSSL.fixed_length_secure_compare(given, @token)
    end
  end
end
