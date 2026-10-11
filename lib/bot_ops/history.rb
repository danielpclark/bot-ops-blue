# frozen_string_literal: true

require "json"
require "fileutils"

module BotOps
  # Hourly usage per source, project and model, kept for 30 days and saved to
  # ~/.config/bot-ops-blue/history.json, so charts reach past the 24 hours a
  # snapshot covers (cloud and other machines report only a day) and survive
  # restarts.
  #
  # Rows are [hour, project, model, client, out, in, cache_read, cache_write,
  # tools, prompts, errors]: the shape of a Probe snapshot's "usage". A snapshot
  # holds each hour's running totals, so recording keeps the larger of the
  # stored and new value for every count.
  # Where history and prefs live; BOT_OPS_CONFIG_DIR overrides it (tests).
  CONFIG_DIR = ENV.fetch("BOT_OPS_CONFIG_DIR", File.join(Dir.home, ".config", "bot-ops-blue"))

  class History
    PATH = File.join(CONFIG_DIR, "history.json")
    KEEP_S = 30 * 24 * 3600
    COUNTS = 7

    def initialize(path: PATH, save_every: 60)
      @path = path
      @save_every = save_every
      @rows = {} # [source, hour, project, model, client] => counts
      @saved_at = Time.now.to_f
      @dirty = false
      load
    end

    def record(source, rows, now: Time.now)
      rows.each do |hour, project, model, client, *counts|
        next unless hour.is_a?(Integer) && counts.size == COUNTS && counts.any? { |n| n.to_i.positive? }
        key = [source, hour, project.to_s, model.to_s, client.to_s]
        supersede(source, hour) unless key[4].empty?
        old = @rows[key]
        merged = old ? old.zip(counts).map { |a, b| [a, b.to_i].max } : counts.map(&:to_i)
        next if merged == old
        @rows[key] = merged
        @dirty = true
      end
      save if @dirty && now.to_f - @saved_at >= @save_every
    end

    # [[source, hour, project, model, client, *counts], ...] since `hour`.
    def rows(since)
      @rows.filter_map { |key, counts| [*key, *counts] if key[1] >= since }
    end

    def save(now: Time.now)
      cutoff = now.to_f - KEEP_S
      @rows.delete_if { |key, _| key[1] < cutoff }
      FileUtils.mkdir_p(File.dirname(@path))
      tmp = "#{@path}.tmp"
      File.write(tmp, JSON.generate(@rows.map { |key, counts| key + counts }), perm: 0o600)
      File.rename(tmp, @path)
      @saved_at = now.to_f
      @dirty = false
    rescue SystemCallError
      nil
    end

    private

    # Rows without a client (saved before rows had one, or a source's
    # tokenless fallback) count the same hour again once tagged rows arrive.
    def supersede(source, hour)
      stale = @rows.keys.select { |k| k[0] == source && k[1] == hour && k[4].empty? }
      return if stale.empty?
      stale.each { |k| @rows.delete(k) }
      @dirty = true
    end

    def load
      return unless File.exist?(@path)
      cutoff = Time.now.to_f - KEEP_S
      JSON.parse(File.read(@path)).each do |row|
        row.insert(4, "") if row.size == 4 + COUNTS # saved before rows had a client
        source, hour, project, model, client, *counts = row
        next unless hour.is_a?(Integer) && hour >= cutoff && counts.size == COUNTS && counts.any? { |n| n.to_i.positive? }
        @rows[[source, hour, project, model, client]] = counts
      end
    rescue JSON::ParserError, SystemCallError
      @rows = {}
    end
  end

  # Small UI preferences that should survive a restart
  # (~/.config/bot-ops-blue/prefs.json).
  class Prefs
    PATH = File.join(CONFIG_DIR, "prefs.json")
    DEFAULTS = { "chart_range" => "12h", "hidden_series" => [], "notifications" => false }.freeze

    def initialize(path: PATH)
      @path = path
      @values = DEFAULTS.merge(read)
    end

    def [](key)
      @values[key.to_s]
    end

    def []=(key, value)
      @values[key.to_s] = value
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.generate(@values), perm: 0o600)
    rescue SystemCallError
      nil
    end

    private

    def read
      File.exist?(@path) ? JSON.parse(File.read(@path)).slice(*DEFAULTS.keys) : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end
  end
end
