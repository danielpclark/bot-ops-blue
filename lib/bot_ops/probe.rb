# frozen_string_literal: true

require "json"
require "etc"
require "socket"
require "time"
require "open3"

module BotOps
  # Reads what Claude Code is doing on *this* machine and returns it as a
  # plain JSON-able snapshot. The dashboard probes its own machine directly;
  # bin/bot-ops-agent runs the same probe on other machines and posts the
  # snapshot to the dashboard's Collector.
  #
  # Sources (all local files, nothing is sent anywhere by the probe itself):
  #   ~/.claude/sessions/<pid>.json        live sessions: name, cwd, status, entrypoint
  #   ~/.claude/projects/*/<id>.jsonl      transcripts: model, tokens, tools, prompts
  #   ~/.claude/bot-ops/hooks.jsonl        optional, from bin/bot-ops-hook: permission
  #                                        prompts, session start/end, finished turns
  #   sysctl / vm_stat / df, or /proc      machine load, memory, disk, uptime
  #
  # The session and transcript files are Claude Code internals rather than a
  # published API, so every field is read defensively: anything missing or
  # unparseable is skipped, never guessed.
  class Probe
    WINDOW_S = 24 * 3600
    RECENT_S = 12 * 3600
    # Hourly usage reaches back further than events: a week for the
    # dashboard's own machine (full_detail), a day in agent snapshots.
    USAGE_DAYS_FULL = 7
    USAGE_DAYS_AGENT = 1
    EVENT_LIMIT = 1000

    # full_detail: also keep each event's full text (a tool call's whole input,
    # a prompt, an error) for the dashboard's detail overlay. On for the
    # dashboard's own probe; off for bin/bot-ops-agent, so snapshots sent over
    # the network stay small and carry excerpts only.
    def initialize(claude_dir: File.join(Dir.home, ".claude"), host: Socket.gethostname.sub(/\.local\z/, ""),
                   full_detail: false)
      @claude_dir = claude_dir
      @host = host
      @transcripts = Transcripts.new(File.join(claude_dir, "projects"), full_detail: full_detail)
      @hooks = HookLog.new(File.join(claude_dir, "bot-ops", "hooks.jsonl"))
      @health = nil
      @health_at = 0
    end

    attr_reader :host

    def snapshot(now = Time.now)
      @transcripts.refresh(now)
      @hooks.refresh(now)
      sessions = live_sessions.map { |s| merge_stats(s) }
      live_ids = sessions.map { |s| s["id"] }
      {
        "host" => @host,
        "user" => Etc.getpwuid(Process.uid)&.name,
        "at" => now.to_f,
        "machine" => machine(now),
        "sessions" => sessions,
        "events" => (@transcripts.events(now) + @hooks.events(now)).sort_by { |e| -e["at"] }.first(EVENT_LIMIT),
        "hooks" => @hooks.installed?,
        "hourly" => @transcripts.hourly(now),
        "usage" => @transcripts.usage(now),
        "projects" => @transcripts.projects(now),
        "recent" => @transcripts.recent(now, live_ids)
      }
    end

    # ---- sessions ----------------------------------------------------------

    def live_sessions
      # map + compact rather than filter_map: the agent also runs on macOS's
      # built-in Ruby 2.6 (e.g. under a second account with no rvm/rbenv).
      Dir.glob(File.join(@claude_dir, "sessions", "*.json")).map do |path|
        s = JSON.parse(File.read(path)) rescue next
        next unless s.is_a?(Hash) && s["sessionId"] && alive?(s["pid"])
        s
      end.compact
    end

    def alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue Errno::EPERM
      true
    rescue StandardError
      false
    end

    def merge_stats(s)
      t = @transcripts.session(s["sessionId"]) || {}
      {
        "id" => s["sessionId"],
        "pid" => s["pid"],
        "name" => s["name"] || File.basename(s["cwd"].to_s),
        "cwd" => s["cwd"],
        "kind" => s["kind"],
        "entrypoint" => s["entrypoint"],
        "status" => s["status"] || "unknown",
        "started_at" => ms(s["startedAt"]),
        "status_at" => ms(s["statusUpdatedAt"] || s["updatedAt"]),
        "version" => s["version"]
      }.merge(t.slice("model", "title", "last_prompt", "branch", "tokens", "context",
                      "tool_calls", "errors", "prompts", "last_tool", "last_at", "prompt_at"))
       .merge(attention(s["sessionId"], t["last_at"]))
    end

    # A permission prompt from the hook log that nothing has happened since.
    def attention(id, last_at)
      n = @hooks.pending_attention(id)
      return {} unless n && n["at"] > last_at.to_f
      { "attention" => n["message"].to_s.empty? ? "Waiting for permission" : n["message"], "attention_at" => n["at"] }
    end

    def ms(v)
      v.is_a?(Numeric) ? v / 1000.0 : nil
    end

    # ---- machine health ------------------------------------------------------

    def machine(now)
      if now.to_f - @health_at > 10
        @health = read_health
        @health_at = now.to_f
      end
      { "os" => RUBY_PLATFORM[/darwin|linux|mingw|mswin/] || RUBY_PLATFORM, "cpus" => Etc.nprocessors }.merge(@health)
    end

    def read_health
      RUBY_PLATFORM.include?("darwin") ? darwin_health : linux_health
    rescue StandardError
      {}
    end

    def darwin_health
      load1 = sh("sysctl", "-n", "vm.loadavg")[/[\d.]+/].to_f
      mem_total = sh("sysctl", "-n", "hw.memsize").to_i
      vm = sh("vm_stat")
      page = vm[/page size of (\d+)/, 1].to_i
      pages = ->(label) { vm[/#{label}:\s+(\d+)/, 1].to_i }
      used = (pages.call("Pages active") + pages.call("Pages wired down") +
              pages.call("Pages occupied by compressor")) * page
      boot = sh("sysctl", "-n", "kern.boottime")[/sec = (\d+)/, 1].to_i
      data_vol = File.directory?("/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
      {
        "load" => load1,
        "mem_pct" => mem_total.positive? ? (used * 100.0 / mem_total).round : nil,
        "disk_pct" => disk_pct(data_vol),
        "uptime_s" => boot.positive? ? (Time.now.to_i - boot) : nil
      }
    end

    def linux_health
      mem = File.read("/proc/meminfo")
      total = mem[/MemTotal:\s+(\d+)/, 1].to_f
      avail = mem[/MemAvailable:\s+(\d+)/, 1].to_f
      {
        "load" => File.read("/proc/loadavg").split.first.to_f,
        "mem_pct" => total.positive? ? ((total - avail) * 100 / total).round : nil,
        "disk_pct" => disk_pct("/"),
        "uptime_s" => File.read("/proc/uptime").split.first.to_f.to_i
      }
    end

    def disk_pct(path)
      sh("df", "-k", path).lines.last.to_s[/(\d+)%/, 1]&.to_i
    end

    def sh(*cmd)
      out, status = Open3.capture2(*cmd, err: File::NULL)
      status.success? ? out : ""
    rescue SystemCallError
      ""
    end

    # Tails ~/.claude/bot-ops/hooks.jsonl (written by bin/bot-ops-hook).
    class HookLog
      LABELS = { "SessionStart" => "session started", "SessionEnd" => "session ended",
                 "Stop" => "turn finished", "Notification" => "needs you" }.freeze

      def initialize(path)
        @path = path
        @offset = 0
        @events = []
        @attention = {}
      end

      def installed?
        File.exist?(@path)
      end

      def refresh(now)
        return unless installed?
        size = File.size(@path)
        @offset = 0 if size < @offset # truncated by the hook
        return if size == @offset
        File.open(@path, "rb") do |f|
          f.seek(@offset)
          f.each_line do |line|
            break unless line.end_with?("\n")
            @offset += line.bytesize
            ingest(JSON.parse(line)) rescue nil
          end
        end
        cutoff = now.to_f - WINDOW_S
        @events.reject! { |e| e["at"] < cutoff }
        @events.shift(@events.size - EVENT_LIMIT) if @events.size > EVENT_LIMIT
      end

      def events(_now)
        @events
      end

      def pending_attention(id)
        @attention[id]
      end

      private

      def ingest(h)
        name = h["hook_event_name"]
        return unless h.is_a?(Hash) && LABELS.key?(name) && h["at"].is_a?(Numeric)
        sid = h["session_id"]
        if name == "Notification"
          # Only permission prompts need you; "waiting for input" is just idle.
          return unless h["notification_type"] == "permission_prompt" || h["message"].to_s =~ /permission/i
          @attention[sid] = h
        else
          @attention.delete(sid)
        end
        detail = h["message"] || h["reason"] || h["source"]
        @events << { "at" => h["at"], "sid" => sid, "project" => File.basename(h["cwd"].to_s),
                     "kind" => name == "Notification" ? "attention" : "lifecycle", "title" => LABELS[name], "detail" => detail.to_s[0, 160] }
      end
    end

    # Incrementally tails every transcript touched in the last 24h. Each file
    # is read from where the previous refresh stopped, so a refresh costs only
    # the lines appended since.
    class Transcripts
      TOOL_DETAIL_KEYS = %w[command file_path pattern url query description prompt skill].freeze

      # Per [project, hour, model]: tokens in each direction, and counts.
      USAGE_FIELDS = %w[out in cache_read cache_write tools prompts errors].freeze
      OUT, IN, CACHE_READ, CACHE_WRITE, TOOLS, PROMPTS, ERRORS = (0...USAGE_FIELDS.size).to_a
      FULL_LIMIT = 12_000   # characters of full text kept per event
      VALUE_LIMIT = 4_000   # per string inside a tool's input

      def initialize(dir, full_detail: false)
        @dir = dir
        @full_detail = full_detail
        @offsets = {}
        @sessions = {}
        @seen = {}
        @events = []
        # [cwd, hour, model, client] => USAGE_FIELDS counts (model "" for tool/prompt/error counts)
        @buckets = Hash.new { |h, k| h[k] = Array.new(USAGE_FIELDS.size, 0) }
        @usage_days = full_detail ? USAGE_DAYS_FULL : USAGE_DAYS_AGENT
        @pending_tools = {} # tool_use_id => [started at, tool name, its event or nil]
      end

      def session(id)
        @sessions[id]
      end

      def refresh(now)
        cutoff = now.to_f - WINDOW_S
        @usage_cutoff = hour_of(now.to_f) - (@usage_days * 24 - 1) * 3600
        files = Dir.glob(File.join(@dir, "*", "*.jsonl")) + Dir.glob(File.join(@dir, "*", "*", "subagents", "*.jsonl"))
        files.each do |path|
          mtime = File.mtime(path).to_f rescue next
          next if mtime < @usage_cutoff && !@offsets.key?(path)
          read_new(path, cutoff)
        end
        prune(now)
      end

      def events(now)
        cutoff = now.to_f - WINDOW_S
        @events.select { |e| e["at"] >= cutoff }.sort_by { |e| -e["at"] }.first(EVENT_LIMIT)
      end

      # [[hour_start_epoch, out_tokens, tool_calls, prompts, errors], ...] oldest first.
      def hourly(now)
        sums = Hash.new { |h, k| h[k] = [0, 0, 0, 0] }
        @buckets.each { |(_, hour, _, _), v| sums[hour] = sums[hour].zip(v.values_at(OUT, TOOLS, PROMPTS, ERRORS)).map(&:sum) }
        first = hour_of(now.to_f) - 23 * 3600
        (0..23).map { |i| h = first + i * 3600; [h, *sums[h]] }
      end

      # [[hour, project, model, client, out, in, cache_read, cache_write,
      # tools, prompts, errors], ...] for the usage window, non-zero rows only.
      # client is the session's entrypoint ("cli", "claude-vscode", ...).
      def usage(_now)
        @buckets.filter_map do |(cwd, hour, model, client), v|
          [hour, File.basename(cwd), model, client, *v] if v.any?(&:positive?)
        end.sort_by(&:first)
      end

      # Sessions with activity in the last RECENT_S whose process has exited
      # (e.g. earlier VS Code conversations), most recent first.
      def recent(now, live_ids)
        cutoff = now.to_f - RECENT_S
        @sessions.values.select { |s| s["last_at"].to_f >= cutoff && !live_ids.include?(s["id"]) && s["cwd"] }
                 .sort_by { |s| -s["last_at"] }
                 .first(40)
                 .map do |s|
                   s.slice("id", "cwd", "entrypoint", "version", "model", "title", "last_prompt", "branch", "tokens",
                           "context", "tool_calls", "errors", "prompts", "last_tool", "last_at", "prompt_at")
                    .merge("name" => s["title"] || File.basename(s["cwd"].to_s), "status" => "ended")
                 end
      end

      def projects(now)
        cutoff = now.to_f - WINDOW_S
        by_cwd = Hash.new { |h, k| h[k] = { "out_tokens" => 0, "tool_calls" => 0, "prompts" => 0 } }
        @buckets.each do |(cwd, hour, _, _), v|
          next if hour < cutoff - 3600
          out, tools, prompts = v.values_at(OUT, TOOLS, PROMPTS)
          p = by_cwd[cwd]
          p["out_tokens"] += out
          p["tool_calls"] += tools
          p["prompts"] += prompts
        end
        @sessions.each_value do |s|
          next unless s["cwd"] && s["last_at"].to_f >= cutoff
          p = by_cwd[s["cwd"]]
          p["sessions"] = p.fetch("sessions", 0) + 1
          p["last_at"] = [p["last_at"].to_f, s["last_at"]].max
          p["branch"] ||= s["branch"]
        end
        by_cwd.map { |cwd, p| p.merge("cwd" => cwd) if p["last_at"] }.compact.sort_by { |p| -p["last_at"] }
      end

      private

      def read_new(path, cutoff)
        offset = @offsets[path] || 0
        size = File.size(path)
        offset = 0 if size < offset # rewritten
        return if size == offset
        sid, sidechain = identify(path)
        File.open(path, "rb") do |f|
          f.seek(offset)
          f.each_line do |line|
            break unless line.end_with?("\n") # partial line; finish it next time
            offset += line.bytesize
            ingest(sid, sidechain, line, cutoff)
          end
        end
        @offsets[path] = offset
      end

      # <project>/<session>.jsonl, or <project>/<session>/subagents/<agent>.jsonl
      def identify(path)
        parts = path.split(File::SEPARATOR)
        parts[-2] == "subagents" ? [parts[-3], true] : [File.basename(path, ".jsonl"), false]
      end

      def ingest(sid, sidechain, line, cutoff)
        d = JSON.parse(line)
        return unless d.is_a?(Hash)
        s = (@sessions[sid] ||= { "id" => sid, "tokens" => { "in" => 0, "out" => 0, "cache_read" => 0, "cache_write" => 0 },
                                  "tool_calls" => 0, "errors" => 0, "prompts" => 0 })
        s["cwd"] ||= d["cwd"]
        unless sidechain
          s["entrypoint"] ||= d["entrypoint"]
          s["version"] = d["version"] if d["version"]
        end
        s["branch"] = d["gitBranch"] if d["gitBranch"] && !sidechain
        at = d["timestamp"] && (Time.iso8601(d["timestamp"]).to_f rescue nil)
        s["last_at"] = [s["last_at"].to_f, at].max if at
        recent = at && at >= cutoff
        @counted = at && at >= @usage_cutoff.to_f
        @client = s["entrypoint"] || d["entrypoint"]
        case d["type"]
        # A title given by hand (/rename, the claude.ai sidebar) beats the generated one.
        when "ai-title" then s["title"] = d["aiTitle"] unless sidechain || s["custom_title"]
        when "custom-title"
          unless sidechain || d["customTitle"].to_s.strip.empty?
            s["title"] = s["custom_title"] = d["customTitle"]
          end
        when "last-prompt" then s["last_prompt"] = one_line(d["lastPrompt"]) unless sidechain
        when "assistant" then ingest_assistant(s, d["message"], sidechain, at, recent)
        when "user" then ingest_user(s, d, sidechain, at, recent)
        when "queue-operation" # a prompt typed while the session was busy
          prompt(s, d["content"], at, recent) if d["operation"] == "enqueue" && !sidechain
        end
      rescue JSON::ParserError
        nil
      end

      def ingest_assistant(s, m, sidechain, at, recent)
        return unless m.is_a?(Hash)
        s["model"] = m["model"] if !sidechain && m["model"].to_s.start_with?("claude")
        # A streamed reply is logged once per content block with the same
        # message id and usage, so count each message's usage once.
        if (u = m["usage"]) && !seen?(s["id"], m["id"])
          t = s["tokens"]
          t["in"] += u["input_tokens"].to_i
          t["out"] += u["output_tokens"].to_i
          t["cache_read"] += u["cache_read_input_tokens"].to_i
          t["cache_write"] += u["cache_creation_input_tokens"].to_i
          s["context"] = u["input_tokens"].to_i + u["cache_read_input_tokens"].to_i + u["cache_creation_input_tokens"].to_i unless sidechain
          if @counted
            b = bucket(s, at, m["model"].to_s)
            b[OUT] += u["output_tokens"].to_i
            b[IN] += u["input_tokens"].to_i
            b[CACHE_READ] += u["cache_read_input_tokens"].to_i
            b[CACHE_WRITE] += u["cache_creation_input_tokens"].to_i
          end
        end
        Array(m["content"]).each do |b|
          next unless b.is_a?(Hash) && b["type"] == "tool_use"
          s["tool_calls"] += 1
          detail = tool_detail(b["input"])
          s["last_tool"] = { "name" => b["name"], "detail" => detail, "at" => at }
          bucket(s, at)[TOOLS] += 1 if @counted
          ev = (event(s, at, "tool", b["name"].to_s, detail, full: (full_input(b["input"]) if @full_detail)) if recent)
          @pending_tools[b["id"]] = [at, b["name"].to_s, ev] if b["id"] && at
        end
      end

      def ingest_user(s, d, sidechain, at, recent)
        c = d.dig("message", "content")
        if c.is_a?(Array)
          c.each do |b|
            next unless b.is_a?(Hash) && b["type"] == "tool_result"
            started, tool, ev = @pending_tools.delete(b["tool_use_id"])
            ev["duration"] = (at - started).round(3) if ev && at && started && at >= started
            next unless b["is_error"]
            ev["failed"] = true if ev
            s["errors"] += 1
            bucket(s, at)[ERRORS] += 1 if @counted
            next unless recent
            text = text_of(b["content"])
            err = event(s, at, "error", "tool error", one_line(text), full: (text if @full_detail))
            err["tool"] = tool if tool
          end
          text = c.map { |b| b["text"] if b.is_a?(Hash) && b["type"] == "text" }.compact.join(" ")
        else
          text = c.to_s
        end
        prompt(s, text, at, recent) unless sidechain || d["isMeta"]
      end

      # Typed prompts only: skips the <command-…>/<task-notification> style
      # wrappers Claude Code also logs as user turns.
      def prompt(s, text, at, recent)
        text = text.to_s
        return if text.strip.empty? || text.lstrip.start_with?("<")
        s["prompts"] += 1
        s["prompt_at"] = [s["prompt_at"].to_f, at].max if at
        bucket(s, at)[PROMPTS] += 1 if @counted
        return unless recent
        ev = event(s, at, "prompt", "prompt", one_line(text), full: (text if @full_detail))
        ev["context"] = s["context"] if s["context"]
      end

      def seen?(sid, msg_id)
        return false unless msg_id
        set = (@seen[sid] ||= {})
        return true if set[msg_id]
        set[msg_id] = true
        false
      end

      def bucket(s, at, model = "")
        @buckets[[s["cwd"].to_s, hour_of(at), model, @client.to_s]]
      end

      def hour_of(t)
        (t.to_i / 3600) * 3600
      end

      def event(s, at, kind, title, detail, full: nil)
        e = { "at" => at, "sid" => s["id"], "project" => File.basename(s["cwd"].to_s), "kind" => kind,
              "title" => title, "detail" => detail.to_s[0, 160] }
        e["full"] = full.to_s[0, FULL_LIMIT] if full && !full.to_s.strip.empty?
        @events << e
        @events.shift(@events.size - EVENT_LIMIT * 2) if @events.size > EVENT_LIMIT * 3
        e
      end

      def prune(now)
        @buckets.delete_if { |(_, hour, _, _), _| hour < @usage_cutoff }
        # A call still pending after a day never got its result.
        @pending_tools.delete_if { |_, (started, _, _)| started < now.to_f - WINDOW_S }
      end

      def tool_detail(input)
        return "" unless input.is_a?(Hash)
        key = TOOL_DETAIL_KEYS.find { |k| input[k].is_a?(String) && !input[k].empty? }
        v = key ? input[key] : ""
        v = v.sub(Dir.home, "~") if key == "file_path"
        one_line(v)
      end

      # A tool call's input for reading: "key: value" per field, with
      # multi-line values (commands, file contents) as indented lines and long
      # strings shortened.
      def full_input(input)
        return input.to_s unless input.is_a?(Hash)
        input.map do |key, v|
          if v.is_a?(String)
            v = "#{v[0, VALUE_LIMIT]}… (#{v.length - VALUE_LIMIT} more characters)" if v.length > VALUE_LIMIT
            v.include?("\n") ? "#{key}:\n#{v.lines.map { |l| "  #{l.chomp}" }.join("\n")}" : "#{key}: #{v}"
          else
            "#{key}: #{JSON.generate(v)}"
          end
        end.join("\n")
      rescue StandardError
        input.to_s
      end

      def text_of(content)
        content.is_a?(Array) ? content.map { |b| b["text"] if b.is_a?(Hash) }.compact.join(" ") : content.to_s
      end

      def one_line(text)
        text.to_s.strip.lines.first.to_s.strip[0, 160]
      end
    end
  end
end
