# Bot Ops Blue

A borderless desktop dashboard for your **live Claude Code sessions**, on
this machine and on any other machine that runs the small reporting agent.
Ruby owns the data, layout and comms; a small Rust extension owns the window
and rendering. The look follows the mock-up in `assets/reference-mockup.png`:
live sessions, live activity, projects, tool calls, hourly usage, machine
health, recent prompts, session details, an event log and a machine list,
plus a sidebar that switches between full-size pages for each area.

Nothing on screen is simulated. Panels with no data show an empty state.

![Bot Ops Blue running](assets/preview.png)

## Setup

You need Ruby 3.0+ and a Rust toolchain ([rustup.rs](https://rustup.rs), one
command on macOS, Linux and Windows). Then:

```sh
bundle exec rake setup   # bundle install + cargo build of the native window
bundle exec rake run     # start the dashboard
```

`rake setup` prints what to install if `cargo` is missing. No GUI toolkit,
no system packages: the window is pure Rust ([egui](https://github.com/emilk/egui)
/ eframe) and the fonts are bundled in the extension.

Other tasks:

| Task | What it does |
| --- | --- |
| `rake test` | Minitest suite over the store, comms, scene and frame protocol (no display or Rust needed) |
| `rake preview` | Renders every page to SVG in `tmp/preview/` (no display or Rust needed) |
| `rake compile` | Rebuilds just the native extension |
| `rake clean` | Removes build artifacts |

### Which monitor

On macOS the window opens centered on your external monitor. If no external
monitor is connected it refuses to start rather than cover the main screen.
To choose a different spot, set an environment variable:

| Variable | Effect |
| --- | --- |
| `BOT_OPS_DISPLAY=external` | First non-main monitor (default); exits if there is none |
| `BOT_OPS_DISPLAY=main` | Leave placement to the OS (main monitor) |
| `BOT_OPS_DISPLAY=2` | Monitor number 2, in macOS's screen order |
| `BOT_OPS_POSITION=x,y` | Exact top-left corner in screen points (any OS) |

```sh
BOT_OPS_DISPLAY=main bundle exec rake run
```

`BOT_OPS_FULLSCREEN=1` starts fullscreen on that monitor.

The window opens without an OS title bar. Drag the header bar to move it.
The three glyphs in the top-right corner restore the title bar, toggle
fullscreen, and quit. The same controls live on the **Settings** page.
In fullscreen macOS slides its menu bar over the top edge, so use the keys:
**Esc** leaves fullscreen, **F11** or **Ctrl+Cmd+F** toggles it.

The layout stretches to the window: the content is zoomed until the
1536x1024 design fits, and the panels widen or grow taller to use the rest,
so a 16:9 monitor is filled edge to edge without black bars.

## Where the data comes from

`BotOps::Probe` reads Claude Code's own files on the machine it runs on.
It sends nothing anywhere and changes no settings:

| Source | Gives |
| --- | --- |
| `~/.claude/sessions/<pid>.json` (pid checked alive) | live sessions: name, cwd, status (busy/idle), entrypoint, version |
| transcripts without a live process | **earlier** sessions from the last 12h (e.g. VS Code conversations you have moved on from), listed below the live ones |
| `~/.claude/projects/*/<session>.jsonl` (+ `subagents/`) | model, tokens, context size, tool calls and errors, prompts, title, git branch |
| `sysctl`, `vm_stat`, `df` (macOS) or `/proc` (Linux) | load, memory, disk, uptime |

Transcripts are tailed: the first scan reads the last 24 hours, then each
one-second refresh reads only the lines appended since. These files are
Claude Code internals, not a published API, so every field is read
defensively and a format change shows up as missing data, never as wrong
data. `claude agents --json` lists the same live sessions if you want to
cross-check.

### Hooks (optional)

`bin/bot-ops-hook` is a Claude Code command hook that appends
SessionStart, SessionEnd, Notification and Stop events to
`~/.claude/bot-ops/hooks.jsonl`. With it registered, a session blocked on a
permission prompt shows **Needs you** (yellow, sorted first) within a
second or two, and starts, ends and finished turns appear in the event log. It
prints nothing, always exits 0 and caps its log at 2 MB. Register it yourself
for those four events (for example with `/hooks`) as
`ruby /path/to/bot-ops-blue/bin/bot-ops-hook`; the Settings page shows
whether events are arriving.

### Adding other accounts and machines

The probe only reads the account it runs as. Sessions from another macOS
account on the same Mac (for example a VS Code window logged in as a
different user), or from another machine, reach the dashboard through
`bin/bot-ops-agent`, run as that account, posting to the dashboard's
collector. Sources are keyed `user@host`, so accounts sharing a Mac show up
separately.

On the account showing the dashboard:

```sh
bundle exec rake token                       # creates ~/.config/bot-ops-blue/token (0600)
BOT_OPS_LISTEN=127.0.0.1:47800 bundle exec rake run   # same Mac only
BOT_OPS_LISTEN=0.0.0.0:47800 bundle exec rake run     # LAN / Tailscale
```

In each other account or machine, with a checkout of this repo and any Ruby
2.6+ (macOS's built-in `/usr/bin/ruby` works, no gems needed), put the same
token in `~/.config/bot-ops-blue/token` (or `BOT_OPS_TOKEN`) and run:

```sh
bin/bot-ops-agent                                         # same Mac
BOT_OPS_COLLECTOR=http://<dashboard-host>:47800 bin/bot-ops-agent   # elsewhere
```

The agent posts a snapshot every 3 seconds (`BOT_OPS_INTERVAL`). A source
that stops reporting turns offline after 15 seconds and its sessions leave
the live views. Snapshots carry prompt excerpts and tool details over plain
HTTP, guarded only by the token, so keep the port on loopback or a network
you trust (LAN, Tailscale, or an SSH tunnel), not the open internet.

### Cloud sessions (claude.ai/code)

Claude Code has no API that lists cloud sessions, so they report
themselves: cloud sessions run the hooks committed in the repo they clone,
and `cloud/bot-ops-report.py` (a Python 3 stdlib hook) forwards a trimmed
copy of each event to the collector's `POST /v1/event`. They appear as the
`claude.ai` source with a ☁ Cloud label, sorted in with everything else.
Events are kept in `~/.config/bot-ops-blue/cloud-events.jsonl` (24h), so
cloud history survives a dashboard restart.

What leaves a cloud session: session id, event name, cwd, git branch,
model, a 300-character prompt excerpt, the tool name with a 160-character
detail (command, file path, pattern or URL), and notification text. Never
file contents or tool output. Without `BOT_OPS_URL` and `BOT_OPS_TOKEN`
the hook does nothing, so it is harmless locally and for collaborators.

1. **Reach the dashboard from the internet with ngrok.**

   | Piece | Address | Notes |
   | --- | --- | --- |
   | Collector | `127.0.0.1:47800` | `BOT_OPS_LISTEN`; loopback only, so only the ngrok agent on this Mac can reach it |
   | ngrok agent | outbound TCP 443 to ngrok | no inbound ports, router forwarding or firewall changes |
   | Public URL | `https://<your-static-domain>.ngrok-free.dev` (443) | forwards to `http://127.0.0.1:47800` |
   | ngrok inspector | `127.0.0.1:4040` | turned off (`--inspect=false`): it would record prompt excerpts |

   The traffic policy (`cloud/ngrok-policy.example.yml`) exposes only
   `/v1/event`, `/v1/snapshot` and `/v1/health` (anything else is a 404 at
   ngrok's edge) and requires HTTP basic auth there, so nothing without the
   password reaches this Mac. The password is the collector token, and the
   collector checks it again. It uses only free-plan actions; rewriting
   headers would need a paid plan (`ERR_NGROK_2263`).

   ```sh
   ngrok config add-authtoken <your ngrok authtoken>   # once
   bundle exec rake ngrok:policy    # writes ~/.config/bot-ops-blue/ngrok-policy.yml + ngrok-basic-auth (0600)
   BOT_OPS_LISTEN=127.0.0.1:47800 bundle exec rake run
   bundle exec rake ngrok:tunnel DOMAIN=<your-static-domain>.ngrok-free.dev
   ```

   Claim the free static domain in the ngrok dashboard (Universal Gateway →
   Domains) so the URL, and the network secret's host, never change.

2. **Configure the cloud environment** (claude.ai/code → the environment's
   **Edit environment** dialog):
   - **Environment variables:** `BOT_OPS_URL=https://<your-static-domain>.ngrok-free.dev`.
     Not the password: values here are visible to anyone using the environment.
   - **Network secrets → Add secret** (Pro and Max plans): allowed website
     `<your-static-domain>.ngrok-free.dev`; header **Name** `Authorization`,
     **Prefix** `Basic`, **Value** the output of the command `rake ngrok:policy`
     prints (base64 of `botops:<collector token>`). Anthropic's agent proxy adds it
     to requests for that host after they leave the session, and a secret's
     hosts are reachable under the default **Trusted** network access, so
     that setting can stay as it is.
   - *Or*, instead of the network secret, add
     `BOT_OPS_TOKEN=<contents of ~/.config/bot-ops-blue/token>` to the
     environment variables. The reporter sends it as Basic auth
     (`botops:<token>`). Simpler, but anyone who can use the environment
     can read it. Use one or the other, not both.

3. **Commit the hook to each repo you use in the cloud.** Cloud sessions run
   hooks from the repository (and server-managed settings), not from a
   user-level `~/.claude/settings.json`, so a setup script can't install it.
   Copy `cloud/bot-ops-report.py` to the repo's `.claude/hooks/` and merge
   `cloud/settings.json` into its `.claude/settings.json`. The hook runs in
   local sessions too, but does nothing there unless `BOT_OPS_URL` is set.
   Sessions that open several repositories at once don't load repository
   hooks, so they won't report.

## How it is put together

```
bot_ops_blue.rb             entry point
bin/bot-ops-agent           reports another machine to the dashboard
cloud/                      hook + hook settings for cloud sessions
lib/bot_ops/
  store.rb                  all dashboard state + Store#apply(event)
  probe.rb                  reads this machine's Claude Code sessions + health
  collector.rb              HTTP endpoint for other machines' snapshots + cloud events
  cloud_feed.rb             turns cloud hook events into the claude.ai source
  comms.rb                  Channel interface, Multiplexer, ClaudeChannel
  display.rb                picks the monitor the window opens on
  scene.rb                  builds a frame from the Store; handles clicks
  panels.rb, widgets.rb     drawing of each panel, on top of Canvas
  canvas.rb                 toolkit-independent display list (+ JSON, + SVG)
  layout.rb, theme.rb       geometry and palette
  native_host.rb            Ruby side of the Ruby <-> Rust protocol
ext/bot_ops_native/         Rust crate: egui window, renderer, Rutie binding
```

The Ruby side never touches a GUI API. `Scene#build` produces a `Canvas`:
a list of drawing commands (rounded rects, circles, lines, wedges, chart
areas, text) plus clickable hit regions. The native side asks for a frame on
every repaint and gets JSON back only when something changed, so idle
repaints cost nothing on the Ruby side.

### The Ruby <-> Rust protocol

`BotOps::Native.run(host, width, height, title)` blocks until the window
closes. While it runs, Rust calls two methods on `host`:

| Call | Returns |
| --- | --- |
| `host.poll` | JSON frame (`cmds`, `hits`, `drag`) when something changed, else `""` |
| `host.hit(id)` | A window command for hit region `id`: `"quit"`, `"fullscreen:toggle"`, `"decorations:toggle"`, or `""` |

Rust handles the drag region (the header) natively, draws the frame, and
executes the window commands. Everything else, including the two-second
refresh tick, lives in Ruby (`BotOps::NativeHost`).

### Why Rutie, and which version

The extension is bound with [Rutie](https://github.com/danielpclark/rutie).
Rutie releases track Ruby's special-constant layout, so the version has to
match the Ruby in use: `rutie = "0.13"` for Ruby 3.x (what `Cargo.toml`
pins), `0.14` for Ruby 4.0. Using 0.9 with Ruby 3 segfaults the first time a
`nil` crosses the boundary, which is why the host protocol only exchanges
strings and integers.

## Adding comms

Everything flows through `BotOps::Store#apply(event)`, where an event is a
plain hash with a `type` key. A comms channel is any object that queues such
hashes; the host drains channels from the refresh tick on the main thread.

```ruby
class SocketChannel < BotOps::Comms::Channel
  def start(_store)
    @thread = Thread.new do
      TCPSocket.open("127.0.0.1", 9000) do |sock|
        sock.each_line { |line| push(JSON.parse(line)) }
      end
    end
  end

  def stop
    @thread && @thread.kill
  end
end
```

Then boot the hub with it in `bot_ops_blue.rb`:

```ruby
channel = BotOps::Comms::Multiplexer.new(SocketChannel.new, BotOps::Comms::ClaudeChannel.new)
BotOps::NativeHost.new(channel: channel).launch
```

Supported event types (see `Store#apply`):

| `type` | Fields |
| --- | --- |
| `snapshot` | `snapshot` (a `Probe#snapshot` hash), `local` (true for this machine) |
| `collector` | `status` (text shown in the header and on Settings) |
| `probe.error` | `message` |

## Platform notes

- **Linux**: needs an X11 or Wayland session with OpenGL (any desktop has
  it). On a bare container add `libxkbcommon-x11-0`.
- **macOS**: the extension is installed as `bot_ops_native.bundle`; Rutie
  links against the Ruby you build with, so use the same Ruby to run.
- **Windows**: build from a shell where `cargo` and `ruby` are on `PATH`
  (RubyInstaller + rustup). The DLL is installed as `bot_ops_native.so`,
  which is the extension Ruby expects there.
