# frozen_string_literal: true

require "yaml"

module BotOps
  # Every colour the dashboard draws comes from the selected theme, a YAML
  # file in themes/ (or ~/.config/bot-ops-blue/themes/). Standard Blue is
  # the default and the fallback for any colour another theme leaves out.
  #
  # Drawing code reaches the colours through `theme` (an includer's shortcut
  # for Theme.current): `fill: col(theme.cyan)`. The module also answers
  # `Theme.cyan` for code that does not include it. Colours are "#RRGGBB"
  # strings; Theme.rgba and Widgets#col make translucent ones.
  module Theme
    FAMILY = "Sans"
    MONO   = "Monospace"

    APP_DIR  = File.expand_path("../../themes", __dir__)
    DEFAULT  = "standard-blue"
    SLUG     = /\A[a-z0-9][a-z0-9-]*\z/
    HEX      = /\A#\h{6}\z/

    # The colour names every theme has (Standard Blue defines them all).
    KEYS = %i[
      bg bg_top panel panel_top panel2 overlay_bg card_top track line border
      edge edge_soft bolt spark
      cyan teal blue purple pink yellow orange red green slate white
      text text_detail muted subtle dim tagline
      stat_tile_top stat_tile_bottom cloud
      nav_active_top nav_active_bottom nav_icon nav_text
      pill_top pill_bottom tile_cyan tile_green health_busy
    ].freeze

    # The role tables: a label -> colour map each, with a "default" entry.
    # status: sessions; priority: tasks; levels: log lines; tools: tool
    # calls by name ("mcp" for MCP tools); kinds: event-log entries; usage:
    # the usage chart's lines.
    TABLES = %i[status priority levels tools kinds usage].freeze

    class Error < StandardError; end

    # One loaded theme. Immutable; switching themes replaces Theme.current.
    class Palette
      attr_reader :slug, :name, :path, :colors, :tables, :series, :mtime

      def initialize(slug:, name:, colors:, tables:, series:, path: nil, mtime: nil)
        @slug = slug
        @name = name
        @colors = colors.freeze
        @tables = tables.freeze
        @series = series.freeze
        @path = path
        @mtime = mtime
      end

      KEYS.each { |key| define_method(key) { @colors[key] } }

      def [](key)
        @colors.fetch(key.to_sym)
      end

      def status_color(status)   = lookup(:status, status)
      def priority_color(level)  = lookup(:priority, level)
      def level_color(level)     = lookup(:levels, level)
      def kind_color(kind)       = lookup(:kinds, kind)
      def usage_color(name)      = lookup(:usage, name)

      def tool_color(name)
        name = name.to_s
        name = "mcp" if name.start_with?("mcp") && !@tables[:tools].key?(name)
        lookup(:tools, name)
      end

      # True when the file behind this theme has been saved since it loaded.
      def stale?
        @path && File.exist?(@path) && File.mtime(@path) != @mtime
      end

      def to_s
        name
      end

      # The colour +table+ (see TABLES) gives +key+, or its default.
      def lookup(table, key)
        t = @tables.fetch(table)
        t[key.to_s] || t["default"]
      end
    end

    # "#RRGGBB" -> [r, g, b] integers
    def self.hex_rgb(hex)
      h = hex.to_s.delete("#")
      [h[0, 2], h[2, 2], h[4, 2]].map { |p| p.to_i(16) }
    end

    # "#RRGGBB" -> [r, g, b, alpha], the colour form Canvas takes
    def self.rgba(hex, alpha = 1.0)
      hex_rgb(hex) + [alpha.to_f]
    end

    # Themes written by the person, outside the checkout.
    def self.user_dir
      File.join(BotOps::CONFIG_DIR, "themes")
    end

    # Where a theme's own images would live once it has any (themes/<slug>/).
    def self.asset_dir(slug = current.slug)
      File.join(File.dirname(find(slug) || File.join(APP_DIR, "#{slug}.yml")), slug)
    end

    # Every theme on disk as [slug, name, path], Standard Blue first, then the
    # app's others, then the person's own (which shadow an app theme of the
    # same slug).
    def self.available
      files = {}
      [APP_DIR, user_dir].each do |dir|
        Dir.glob(File.join(dir, "*.yml")).sort.each do |path|
          slug = File.basename(path, ".yml")
          files[slug] = path if slug.match?(SLUG)
        end
      end
      files.map { |slug, path| [slug, (name_of(path) || slug), path] }
           .sort_by { |slug, name, _| [slug == DEFAULT ? 0 : 1, name.downcase] }
    end

    def self.find(slug)
      available.find { |s, _, _| s == slug }&.last
    end

    # The theme in use. Standard Blue until something selects another.
    def self.current
      @current ||= standard
    end

    def self.standard
      @standard ||= load_file(File.join(APP_DIR, "#{DEFAULT}.yml"), base: nil)
    end

    # Selects the theme +slug+. Returns true when it loaded; false (with a
    # line on stderr) when there is no such theme or its file is broken, in
    # which case the theme in use stays. Standard Blue always loads.
    def self.use(slug)
      slug = slug.to_s
      return (@current = standard) && true if slug.empty? || slug == DEFAULT
      path = find(slug)
      raise Error, "no theme #{slug.inspect} in #{APP_DIR} or #{user_dir}" unless path
      @current = load_file(path, base: standard)
      true
    rescue Error, SystemCallError => e
      warn "bot_ops: theme #{slug.inspect} not used: #{e.message}"
      false
    end

    # Re-reads the current theme when its file changed on disk, so a theme
    # can be edited while the dashboard runs. True when it reloaded.
    def self.reload_if_changed
      return false unless current.stale?
      @standard = nil if current.slug == DEFAULT
      use(current.slug)
    end

    def self.reset!
      @current = nil
      @standard = nil
    end

    # Reads one theme file over +base+ (the theme whose colours fill in what
    # the file leaves out). Raises Theme::Error on anything malformed.
    def self.load_file(path, base: standard)
      data = YAML.safe_load(File.read(path)) || {}
      raise Error, "#{path}: expected a mapping at the top level" unless data.is_a?(Hash)
      slug = File.basename(path, ".yml")
      name = data["name"].to_s.strip
      name = slug if name.empty?
      colors = resolve_colors(data["colors"] || {}, base, path)
      tables = TABLES.to_h { |t| [t, resolve_table(t, data[t.to_s] || {}, colors, base, path)] }
      series = resolve_series(data["series"], colors, base, path)
      Palette.new(slug: slug, name: name, colors: colors, tables: tables, series: series, path: path, mtime: File.mtime(path))
    rescue Psych::Exception => e
      raise Error, "#{path}: #{e.message}"
    end

    KEYS.each { |key| define_singleton_method(key) { current.public_send(key) } }

    def self.series = current.series

    def self.status_color(status)    = current.status_color(status)
    def self.priority_color(level)   = current.priority_color(level)
    def self.level_color(level)      = current.level_color(level)
    def self.tool_color(name)        = current.tool_color(name)
    def self.kind_color(kind)        = current.kind_color(kind)
    def self.usage_color(name)       = current.usage_color(name)

    # For classes that `include Theme`: the palette in use.
    def theme
      Theme.current
    end

    class << self
      private

      def name_of(path)
        data = YAML.safe_load(File.read(path))
        data.is_a?(Hash) ? data["name"]&.to_s : nil
      rescue Psych::Exception, SystemCallError
        nil
      end

      # Each colour is a hex or the name of another colour in the same file
      # (or, failing that, in the base theme). Missing colours come from the
      # base; Standard Blue has to define them all.
      def resolve_colors(given, base, path)
        raise Error, "#{path}: `colors` must be a mapping" unless given.is_a?(Hash)
        given = given.to_h { |k, v| [k.to_s.to_sym, v] }
        given.each_key do |k|
          raise Error, "#{path}: unknown colour #{k.inspect} (see themes/#{DEFAULT}.yml)" unless KEYS.include?(k)
        end
        resolved = {}
        KEYS.each do |key|
          resolved[key] = if given.key?(key)
                            resolve_value(given[key], given, base, path, [key])
                          elsif base
                            base[key]
                          else
                            raise Error, "#{path}: missing colour #{key.inspect}"
                          end
        end
        resolved
      end

      def resolve_value(value, given, base, path, trail)
        s = value.to_s.strip
        return s.upcase if s.match?(HEX)
        ref = s.to_sym
        unless KEYS.include?(ref)
          raise Error, "#{path}: #{trail.first.inspect} is #{value.inspect}, not a \"#RRGGBB\" colour or a colour name"
        end
        raise Error, "#{path}: #{trail.first.inspect} refers to itself (#{trail.join(' -> ')})" if trail.include?(ref)
        return resolve_value(given[ref], given, base, path, trail + [ref]) if given.key?(ref)
        raise Error, "#{path}: #{trail.first.inspect} refers to #{ref.inspect}, which no theme defines" unless base
        base[ref]
      end

      # The chart series: a list of colour names or hexes; from the base when
      # the file has none.
      def resolve_series(given, colors, base, path)
        if given.nil?
          raise Error, "#{path}: needs a `series` list" unless base
          return base.series
        end
        raise Error, "#{path}: `series` must be a list of colours" unless given.is_a?(Array) && !given.empty?
        given.map do |value|
          s = value.to_s.strip
          c = s.match?(HEX) ? s.upcase : colors[s.to_sym]
          raise Error, "#{path}: series entry #{value.inspect} is not a colour or a colour name" unless c
          c
        end
      end

      def resolve_table(table, given, colors, base, path)
        raise Error, "#{path}: `#{table}` must be a mapping" unless given.is_a?(Hash)
        from_base = base ? base.tables[table] : {}
        rows = given.to_h do |label, value|
          s = value.to_s.strip
          c = s.match?(HEX) ? s.upcase : colors[s.to_sym]
          raise Error, "#{path}: #{table} #{label.inspect} is #{value.inspect}, not a colour or a colour name" unless c
          [label.to_s, c]
        end
        merged = from_base.merge(rows)
        raise Error, "#{path}: `#{table}` needs a `default` colour" unless merged["default"]
        merged
      end
    end
  end
end
