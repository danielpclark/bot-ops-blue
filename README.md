# Bot Ops Blue

A borderless desktop operations dashboard for a fleet of bots. Ruby owns the
data, layout and comms; a small Rust extension owns the window and rendering.
It reproduces the reference mock-up in `assets/reference-mockup.png`: bot
fleet, live activity, workflows, task queue, pipeline chart, system health
gauges, recent activity, agent details, logs and reports, plus a sidebar that
switches between full-size pages for each area.

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

The window opens without an OS title bar. Drag the header bar to move it.
The three glyphs in the top-right corner restore the title bar, toggle
fullscreen, and quit. The same controls live on the **Settings** page.

## How it is put together

```
bot_ops_blue.rb             entry point
lib/bot_ops/
  store.rb                  all dashboard state + Store#apply(event)
  comms.rb                  Channel interface, Multiplexer, SimulatedChannel
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
| `host.hit(id)` | A window command for hit region `id`: `"quit"`, `"fullscreen:on/off"`, `"decorations:on/off"`, or `""` |

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
channel = BotOps::Comms::Multiplexer.new(SocketChannel.new, BotOps::Comms::SimulatedChannel.new)
BotOps::NativeHost.new(channel: channel).launch
```

Supported event types (see `Store#apply`):

| `type` | Fields |
| --- | --- |
| `progress` | `bot_id`, `progress` (0-100) |
| `activity.add` / `activity.status` | `bot_id`, `task`, `progress`, `status` |
| `bot.status` | `bot_id`, `status`, `tasks` |
| `task.add` / `task.status` | `id`, `title`, `agent`, `priority`, `status` |
| `workflow` | `id`, `done`, `status` |
| `log` | `level` (INFO/WARN/ERROR), `message` |
| `event` | `bot_id`, `message` |
| `health` | `cpu`, `memory`, `network`, `storage`, `response_ms`, `error_rate` |
| `pipeline` | `input`, `processing`, `review`, `output` |
| `series.push` | `label`, `values` (`created`, `processing`, `completed`, `failed`) |
| `stat` | `label`, `value`, `delta`, `delta_dir`, `delta_color` |
| `agent.detail` | `bot_id`, `task`, `progress`, `started_at`, `model`, `capabilities` |
| `system` | `online` |
| `fleet.total` | `total` |
| `tick` | `seconds` |

## Platform notes

- **Linux**: needs an X11 or Wayland session with OpenGL (any desktop has
  it). On a bare container add `libxkbcommon-x11-0`.
- **macOS**: the extension is installed as `bot_ops_native.bundle`; Rutie
  links against the Ruby you build with, so use the same Ruby to run.
- **Windows**: build from a shell where `cargo` and `ruby` are on `PATH`
  (RubyInstaller + rustup). The DLL is installed as `bot_ops_native.so`,
  which is the extension Ruby expects there.
