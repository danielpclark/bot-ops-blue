# frozen_string_literal: true

module BotOps
  Bot      = Struct.new(:id, :name, :role, :status, :tasks, :uptime_s, :color, :glyph)
  Activity = Struct.new(:bot_id, :task, :started_at, :progress, :status)
  Workflow = Struct.new(:id, :name, :steps, :status, :done, :total, :color, :glyph)
  Task     = Struct.new(:id, :title, :agent, :priority, :status, :created_at)
  Event    = Struct.new(:bot_id, :message, :at)
  LogLine  = Struct.new(:time, :level, :message)
  Report   = Struct.new(:name, :at, :kind, :color)
  Stat     = Struct.new(:label, :value, :delta, :delta_dir, :delta_color)

  # The single source of truth for everything the hub draws.
  #
  # The UI never mutates the store directly. Instead, comms channels (or the
  # built-in simulator) produce event hashes which are fed to Store#apply.
  # This keeps the door open for a real transport (socket, HTTP, stdin) later:
  # anything that can produce `{ type: "...", ... }` hashes can drive the hub.
  class Store
    attr_reader :bots, :activity, :workflows, :tasks, :events, :logs, :reports,
                :pipeline_stages, :series, :series_labels, :health, :stats,
                :system_online, :quote, :agent_detail, :queue_counts, :fleet_total
    attr_accessor :activity_tab, :queue_filter, :page, :selected_bot_id

    def initialize
      @listeners = []
      @activity_tab = :live
      @queue_filter = :all
      @page = :overview
      seed!
    end

    def on_change(&blk)
      @listeners << blk
    end

    def bot(id)
      @bots.find { |b| b.id == id }
    end

    def selected_bot
      bot(@selected_bot_id) || @bots.first
    end

    def visible_activity
      case @activity_tab
      when :queue     then @activity.select { |a| a.status == "Pending" }
      when :completed then @activity.select { |a| a.status == "Completed" }
      when :errors    then @activity.select { |a| a.status == "Failed" }
      else                 @activity.reject { |a| a.status == "Pending" }
      end
    end

    def visible_tasks
      case @queue_filter
      when :pending then @tasks.select { |t| t.status == "Pending" }
      when :running then @tasks.select { |t| t.status == "Running" }
      when :failed  then @tasks.select { |t| t.status == "Failed" }
      else               @tasks
      end
    end

    # ---- event ingestion -------------------------------------------------

    def apply(event)
      type = (event[:type] || event["type"]).to_s
      ev = symbolize(event)
      case type
      when "progress"        then apply_progress(ev)
      when "activity.add"    then @activity.unshift(Activity.new(ev[:bot_id], ev[:task], ev[:at] || Time.now, ev[:progress] || 0, ev[:status] || "Running"))
      when "activity.status" then (a = @activity.find { |x| x.bot_id == ev[:bot_id] }) && (a.status = ev[:status])
      when "bot.status"      then (b = bot(ev[:bot_id])) && (b.status = ev[:status]; b.tasks = ev[:tasks] if ev[:tasks])
      when "task.status"     then (t = @tasks.find { |x| x.id == ev[:id] }) && (t.status = ev[:status])
      when "task.add"        then @tasks.unshift(Task.new(ev[:id], ev[:title], ev[:agent], ev[:priority] || "Medium", ev[:status] || "Pending", ev[:at] || Time.now))
      when "workflow"        then (w = @workflows.find { |x| x.id == ev[:id] }) && (w.done = ev[:done] if ev[:done]; w.status = ev[:status] if ev[:status])
      when "log"             then push_log(ev[:level] || "INFO", ev[:message], ev[:at] || Time.now)
      when "event"           then @events.unshift(Event.new(ev[:bot_id], ev[:message], ev[:at] || Time.now)); @events.pop while @events.size > 12
      when "health"          then @health.merge!(ev.reject { |k, _| k == :type })
      when "pipeline"        then @pipeline_stages.each { |s| s[:count] = ev[s[:key]] if ev[s[:key]] }
      when "series.push"     then push_series_point(ev[:label], ev[:values])
      when "stat"            then apply_stat(ev)
      when "fleet.total"     then @fleet_total = ev[:total].to_i
      when "system"          then @system_online = ev[:online] != false
      when "agent.detail"    then @agent_detail.merge!(ev.reject { |k, _| k == :type })
      when "tick"            then tick_clocks(ev[:seconds] || 1)
      else
        push_log("WARN", "Unknown event type: #{type}")
      end
      changed!
      self
    end

    def apply_all(events)
      Array(events).each { |e| apply(e) }
    end

    def changed!
      @listeners.each { |l| l.call(self) }
    end

    # ---- formatting helpers ---------------------------------------------

    def self.ago(time, now = Time.now)
      secs = (now - time).to_i
      return "just now" if secs < 60
      mins = secs / 60
      return "#{mins}m ago" if mins < 60
      "#{mins / 60}h #{mins % 60}m ago"
    end

    def self.duration(secs)
      m = (secs / 60).to_i
      m < 60 ? "#{m}m" : format("%dh %02dm", m / 60, m % 60)
    end

    private

    def symbolize(h)
      h.each_with_object({}) { |(k, v), o| o[k.to_sym] = v }
    end

    def apply_progress(ev)
      a = @activity.find { |x| x.bot_id == ev[:bot_id] }
      return unless a
      a.progress = [[ev[:progress].to_i, 0].max, 100].min
      a.status = "Completed" if a.progress >= 100 && a.status == "Running"
    end

    def apply_stat(ev)
      s = @stats.find { |x| x.label == ev[:label] }
      return unless s
      s.value = ev[:value] if ev[:value]
      s.delta = ev[:delta] if ev[:delta]
      s.delta_dir = ev[:delta_dir] if ev[:delta_dir]
      s.delta_color = ev[:delta_color] if ev[:delta_color]
    end

    def push_log(level, message, at = Time.now)
      @logs.unshift(LogLine.new(at, level, message))
      @logs.pop while @logs.size > 40
    end

    def push_series_point(label, values)
      @series_labels << label
      @series.each { |s| s[:values] << (values[s[:key]] || s[:values].last || 0) }
      max = 7
      if @series_labels.size > max
        @series_labels.shift
        @series.each { |s| s[:values].shift }
      end
    end

    def tick_clocks(seconds)
      @bots.each { |b| b.uptime_s += seconds if b.status == "Running" }
      @health[:uptime_s] += seconds
    end

    # ---- seed data (mirrors the reference mock-up) ----------------------

    def seed!
      now = Time.now
      t = Theme
      @system_online = true
      @quote = "\"Small, consistent improvements compound into extraordinary results.\""

      @stats = [
        Stat.new("TOTAL BOTS",      "48",    "2",   :up,   t::TEAL),
        Stat.new("ACTIVE",          "42",    "3",   :up,   t::TEAL),
        Stat.new("RUNNING TASKS",   "312",   "18",  :up,   t::TEAL),
        Stat.new("COMPLETED (24H)", "1,482", "22%", :up,   t::TEAL),
        Stat.new("FAILED (24H)",    "7",     "67%", :down, t::RED)
      ]

      @bots = [
        Bot.new(:content,    "Content Creator",  "Video / Social",      "Running", 12, 2 * 3600 + 14 * 60, t::CYAN,   "▶"),
        Bot.new(:research,   "Research Agent",   "Research / Analysis", "Running", 8,  1 * 3600 + 3 * 60,  t::YELLOW, "⌕"),
        Bot.new(:support,    "Customer Support", "Support / CRM",       "Running", 5,  46 * 60,            t::TEAL,   "☺"),
        Bot.new(:marketing,  "Marketing Agent",  "Marketing / Growth",  "Running", 9,  2 * 3600 + 37 * 60, t::BLUE,   "⚑"),
        Bot.new(:sales,      "Sales Agent",      "Outreach / CRM",      "Running", 6,  1 * 3600 + 22 * 60, t::PURPLE, "✉"),
        Bot.new(:data,       "Data Analyst",     "Data / Insights",     "Running", 4,  1 * 3600 + 11 * 60, t::PINK,   "∴"),
        Bot.new(:automation, "Automation Agent", "Ops / Integrations",  "Running", 7,  3 * 3600 + 5 * 60,  t::GREEN,  "⚙"),
        Bot.new(:devops,     "DevOps Agent",     "Infra / Monitoring",  "Idle",    0,  12 * 60,            t::CYAN,   "☁")
      ]
      @selected_bot_id = :content
      @fleet_total = 48

      @activity = [
        Activity.new(:content,    "Generating video clips for TikTok", now - 2 * 60, 78,  "Running"),
        Activity.new(:research,   "Analyzing market trends",           now - 3 * 60, 52,  "Running"),
        Activity.new(:sales,      "Sending outreach emails",           now - 4 * 60, 34,  "Running"),
        Activity.new(:support,    "Processing support tickets",        now - 5 * 60, 61,  "Running"),
        Activity.new(:marketing,  "Creating ad variations",            now - 6 * 60, 43,  "Running"),
        Activity.new(:data,       "Updating dashboard metrics",        now - 7 * 60, 89,  "Running"),
        Activity.new(:automation, "Processing scheduled workflow",     now - 8 * 60, 100, "Completed"),
        Activity.new(:devops,     "Deploying to production",           now - 9 * 60, 25,  "Running"),
        Activity.new(:research,   "Summarizing competitor pricing",    now - 12 * 60, 0,  "Pending"),
        Activity.new(:sales,      "Refreshing lead list",              now - 15 * 60, 0,  "Pending"),
        Activity.new(:devops,     "Rotating API credentials",          now - 40 * 60, 60, "Failed")
      ]

      @workflows = [
        Workflow.new(:youtube,  "YouTube Video Pipeline", ["Content Creator", "Editor", "Publisher"], "Running", 3, 5, t::CYAN,   "▶"),
        Workflow.new(:blog,     "Blog Post Automation",   ["Research", "Write", "Publish"],           "Running", 2, 4, t::TEAL,   "✎"),
        Workflow.new(:support,  "Customer Support Flow",  ["Ticket", "Analyze", "Respond"],           "Running", 5, 7, t::YELLOW, "✉"),
        Workflow.new(:sales,    "Sales Outreach",         ["Find Leads", "Personalize", "Send"],      "Running", 4, 6, t::BLUE,   "⌖"),
        Workflow.new(:social,   "Social Media Scheduler", ["Create", "Approve", "Post"],              "Running", 2, 3, t::GREEN,  "☼"),
        Workflow.new(:dataproc, "Data Processing",        ["Ingest", "Transform", "Store"],           "Running", 1, 4, t::PURPLE, "☰")
      ]

      @tasks = [
        Task.new(7843, "Generate video clips",   "Content Creator", "High",   "Running", now - 2 * 60),
        Task.new(7842, "Research keywords",      "Research Agent",  "High",   "Running", now - 4 * 60),
        Task.new(7841, "Send outreach emails",   "Sales Agent",     "Medium", "Running", now - 7 * 60),
        Task.new(7840, "Analyze performance",    "Data Analyst",    "Medium", "Running", now - 11 * 60),
        Task.new(7839, "Process support ticket", "Support Agent",   "Medium", "Pending", now - 14 * 60),
        Task.new(7838, "Create ad variations",   "Marketing Agent", "Medium", "Pending", now - 18 * 60),
        Task.new(7837, "Update dashboard",       "Data Analyst",    "Low",    "Pending", now - 22 * 60),
        Task.new(7836, "Deploy to production",   "DevOps Agent",    "High",   "Pending", now - 27 * 60),
        Task.new(7835, "Transcribe webinar",     "Content Creator", "Low",    "Pending", now - 31 * 60),
        Task.new(7834, "Sync CRM contacts",      "Sales Agent",     "Medium", "Failed",  now - 38 * 60),
        Task.new(7833, "Rebuild search index",   "Data Analyst",    "High",   "Failed",  now - 44 * 60)
      ]
      @queue_counts = { all: 24, pending: 12, running: 8, failed: 4 }

      @pipeline_stages = [
        { key: :input,      name: "Input",      count: 48, glyph: "⬇" },
        { key: :processing, name: "Processing", count: 32, glyph: "⚙" },
        { key: :review,     name: "Review",     count: 16, glyph: "⚑" },
        { key: :output,     name: "Output",     count: 12, glyph: "⬆" }
      ]

      @series_labels = %w[12:00 13:00 14:00 15:00 16:00 17:00 18:00]
      @series = [
        { key: :created,    name: "Created",    color: t::TEAL,   values: [30, 32, 40, 45, 47, 50, 58] },
        { key: :processing, name: "Processing", color: t::BLUE,   values: [20, 23, 32, 30, 36, 40, 44] },
        { key: :completed,  name: "Completed",  color: t::PURPLE, values: [10, 14, 18, 15, 22, 26, 30] },
        { key: :failed,     name: "Failed",     color: t::RED,    values: [8, 9, 9, 7, 8, 7, 11] }
      ]

      @health = {
        cpu: 28, memory: 54, network: 12, storage: 42,
        uptime_s: 12 * 86_400 + 6 * 3600, response_ms: 482, error_rate: 0.6
      }

      @events = [
        Event.new(:content,   "Completed video clip upload (15 clips)", now - 2 * 60),
        Event.new(:research,  "Finished market analysis report",        now - 4 * 60),
        Event.new(:sales,     "Sent 27 outreach emails",                now - 6 * 60),
        Event.new(:support,   "Resolved 12 tickets",                    now - 8 * 60),
        Event.new(:marketing, "Published 3 posts",                      now - 11 * 60),
        Event.new(:devops,    "Deployed to production",                 now - 16 * 60)
      ]

      @agent_detail = {
        bot_id: :content, task: "Generate 15 video clips", progress: 73,
        started_at: now - 2 * 60, model: "Claude Sonnet 5.5",
        capabilities: ["Video generation", "Image generation", "Script writing", "Social media optimization"]
      }

      @logs = [
        LogLine.new(now - 0 * 60,  "INFO", "Generated video clip #12/15"),
        LogLine.new(now - 2 * 60,  "INFO", "Downloaded media assets"),
        LogLine.new(now - 6 * 60,  "INFO", "Processing with ffmpeg (AV1)"),
        LogLine.new(now - 9 * 60,  "INFO", "Uploaded to YouTube (part)"),
        LogLine.new(now - 13 * 60, "INFO", "Completed analysis (keyword: faith)"),
        LogLine.new(now - 16 * 60, "WARN", "Rate limit approaching (API)"),
        LogLine.new(now - 18 * 60, "INFO", "Retrying request (3/3)"),
        LogLine.new(now - 20 * 60, "INFO", "Task completed successfully")
      ]

      day = Time.new(now.year, now.month, now.day)
      @reports = [
        Report.new("Daily Bot Performance",  day + 18 * 3600,       "PDF", t::RED),
        Report.new("Content Growth Report",  day + 12 * 3600,       "XLS", t::TEAL),
        Report.new("Sales Pipeline Report",  day + 9 * 3600,        "XLS", t::BLUE),
        Report.new("System Health Report",   day + 6 * 3600,        "SYS", t::PURPLE),
        Report.new("Marketing Performance",  day - 6 * 3600,        "XLS", t::YELLOW)
      ]
    end
  end
end
