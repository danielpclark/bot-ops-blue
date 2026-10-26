# Showing assistant bots' routine runs on Bot Ops Blue

Bot Ops Blue reads Claude Code sessions from disk and takes cloud sessions
through its collector. Assistant bots that run scheduled routines on another
machine (the Grok Bot box with Bot Ops, George and the legal-team bots, for
instance) can report through the same collector: a small reporter wraps each
routine's command and posts what happens to the dashboard.

Runs show as **Routine** sessions in Claude Sessions and Live Activity, their
steps and errors land in the Event Log, and every bot gets a card on the
**Bots** page with a dot for each run of the last 24 hours.

- [How it works](#how-it-works)
- [What you need](#what-you-need)
- [1. Run the dashboard with its collector](#1-run-the-dashboard-with-its-collector)
- [2. Open the tunnel](#2-open-the-tunnel)
- [3. Install the reporter on the bot machine](#3-install-the-reporter-on-the-bot-machine)
- [4. Wrap each routine](#4-wrap-each-routine)
- [5. Check that it works](#5-check-that-it-works)
- [Reporting from inside a routine](#reporting-from-inside-a-routine)
- [Over Tailscale instead of a tunnel](#over-tailscale-instead-of-a-tunnel)
- [What leaves the bot machine](#what-leaves-the-bot-machine)
- [Troubleshooting](#troubleshooting)

## How it works

```
 bot machine (Linux)                         ngrok edge                 your machine
┌────────────────────────────────┐  POST   ┌────────────────────┐    ┌──────────────────────────┐
│ cron / systemd timer           │/v1/bot- │ 404 unless a       │    │ collector 127.0.0.1:47800│
│   bot-ops-bot-report.py wrap … │  event  │ collector path;    ├───►│ checks the token again   │
│     └─ the routine's command   ├────────►│ basic auth checked │    │ → BotFeed → Bots page    │
│ Authorization: Basic           │         │ here               │    └──────────────────────────┘
│   botops:<token>               │         └────────────────────┘
└────────────────────────────────┘
```

- **Only scheduled routine runs report.** The reporter wraps the routine's
  command. When the command starts it sends `run_start`; while it runs, a
  `heartbeat` every 60 seconds; when it exits, `run_end` with the last line
  the command printed, or `run_error` with its last line of stderr. Chat
  with a bot is not reported.
- **One shared token** for every bot, sent as HTTP Basic auth
  (`botops:<token>`), the same credential the ngrok edge checks for cloud
  sessions. There are no per-bot tokens.
- **The collector** turns the events into a `bots` source. A run is a
  session whose "project" is the bot's name. A run that stops sending
  heartbeats for 5 minutes is marked **stale**: it shows as ended, with one
  "run went silent" error. Events are kept 24 hours in
  `~/.config/bot-ops-blue/bot-events.jsonl`, so they survive a restart.
- **A failed POST is spooled** on the bot machine
  (`~/.cache/bot-ops-blue/bot-spool.jsonl`) and sent after the next one
  that succeeds, so a tunnel outage loses nothing from the last 24 hours.

## What you need

| | |
| --- | --- |
| Bot Ops Blue | Set up and running ([README](../README.md#setup)), with the collector on (below). |
| A route from the bot machine to the collector | The ngrok tunnel from [cloud sessions](cloud-sessions.md), or Tailscale ([below](#over-tailscale-instead-of-a-tunnel)). |
| On the bot machine | Python 3.6 or later. The reporter uses nothing else. |

## 1. Run the dashboard with its collector

```sh
bundle exec rake token        # writes ~/.config/bot-ops-blue/token (mode 0600), once
BOT_OPS_LISTEN=127.0.0.1:47800 bundle exec rake run
```

The header shows **Collecting on 127.0.0.1:47800 (+ cloud, bots)** when the
collector is up.

## 2. Open the tunnel

If you already use the ngrok tunnel for cloud sessions, regenerate its
traffic policy so the edge lets `/v1/bot-event` through, then restart the
tunnel:

```sh
bundle exec rake ngrok:policy
bundle exec rake ngrok:tunnel DOMAIN=<your-domain>
```

Policies written before the Bots page answer `404` to `/v1/bot-event` at the
edge. The template ([`cloud/ngrok-policy.example.yml`](../cloud/ngrok-policy.example.yml))
allows four paths: `/v1/event`, `/v1/bot-event`, `/v1/snapshot` and
`/v1/health`.

Setting the tunnel up for the first time: follow steps 1 and 2 of
[docs/cloud-sessions.md](cloud-sessions.md).

## 3. Install the reporter on the bot machine

Copy [`cloud/bot-ops-bot-report.py`](../cloud/bot-ops-bot-report.py) to the
bot machine and give it the collector's address and token. The reporter
reads:

| Variable | Meaning |
| --- | --- |
| `BOT_OPS_URL` | `https://<your-domain>` (the tunnel), or `http://<tailscale ip>:47800`. Required. |
| `BOT_OPS_TOKEN` | The collector token. Or: |
| `BOT_OPS_TOKEN_FILE` | A file holding it. Default `~/.config/bot-ops-blue/bot-token`. |
| `BOT_OPS_HEARTBEAT_S` | Seconds between heartbeats while a wrapped command runs. Default 60. |

For example, as the user the bots run as:

```sh
install -D -m 755 bot-ops-bot-report.py ~/bin/bot-ops-bot-report.py
install -d -m 700 ~/.config/bot-ops-blue
umask 077; printf '%s\n' '<contents of ~/.config/bot-ops-blue/token on your machine>' > ~/.config/bot-ops-blue/bot-token
echo 'export BOT_OPS_URL=https://<your-domain>' >> ~/.profile
```

Cron and systemd timers don't read `~/.profile`; set `BOT_OPS_URL` in the
crontab itself or in the unit's `Environment=`.

## 4. Wrap each routine

Put the reporter in front of each scheduled command. Everything after `--`
runs exactly as before, with its stdout and stderr passed through and its
exit code kept:

```sh
bot-ops-bot-report.py wrap --bot "Bot Ops" --routine nightly-digest \
  --title "Compile nightly ops digest" -- python3 /opt/bots/digest.py

bot-ops-bot-report.py wrap --bot "Legal - Contracts" --team legal --routine nda-review \
  -- /opt/bots/legal/review-ndas.sh
```

| Option | |
| --- | --- |
| `--bot` | The bot's name, as the dashboard shows it. Runs are grouped by it. |
| `--routine` | The routine's name (shown under the run). |
| `--title` | What the run is called in the session list; defaults to the routine's name. |
| `--team` | Shown on the bot's card. |

A crontab line:

```
15 2 * * *  BOT_OPS_URL=https://<your-domain> ~/bin/bot-ops-bot-report.py wrap --bot "Bot Ops" --routine nightly-digest -- python3 /opt/bots/digest.py
```

The command's last stdout line becomes the run's **result** on the Bots page
(so end a routine by printing one line that sums it up); on a non-zero exit,
its last stderr line, or `exit N`, becomes the **error**.

Without `BOT_OPS_URL` or a token the wrapper still runs the command and
keeps its exit code. It just doesn't report.

## 5. Check that it works

From the bot machine, with `T` set to the token:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -u "botops:$T" -H 'Content-Type: application/json' \
  -d '{"bot":"Bot Ops","bot_event":"run_start","run_id":"r_check1","routine":"smoke","at":'"$(date +%s)"'}' \
  "$BOT_OPS_URL/v1/bot-event"          # 204
BOT_OPS_TOKEN=$T bot-ops-bot-report.py wrap --bot "Bot Ops" --routine smoke -- sh -c 'sleep 2; echo ok'
```

(In fish: `set -x T (cat ~/.config/bot-ops-blue/bot-token)` and
`-d '{…,"at":'(date +%s)'}'`.)

On the dashboard the run appears at the top of Claude Sessions labeled
**Routine**, the `bots` source shows under Machines, and the **Bots** page
has a card for *Bot Ops* with a green dot for the run. The `r_check1` run
has no wrapper to end it, so after 5 minutes it turns **stale**.

## Reporting from inside a routine

A routine that wants to show its steps sends the events itself. Pick a run
id (letters, digits, `_` and `-`, up to 128) and keep it for the run:

```sh
R=r_$(date +%s)
bot-ops-bot-report.py run_start --bot "Bot Ops" --run $R --routine nightly-digest --title "Compile nightly ops digest"
bot-ops-bot-report.py task      --bot "Bot Ops" --run $R --task drive.search --detail "incidents since yesterday"
bot-ops-bot-report.py task      --bot "Bot Ops" --run $R --task docs.write --error "quota exceeded"
bot-ops-bot-report.py heartbeat --bot "Bot Ops" --run $R        # every minute while working
bot-ops-bot-report.py run_end   --bot "Bot Ops" --run $R --result "Digest written: 4 incidents, 0 open"
bot-ops-bot-report.py run_error --bot "Bot Ops" --run $R --error "Drive download 403 on Acme_NDA_v3.docx"
```

`task` counts as a tool call on the dashboard; one with `--error` counts as
a tool error too. A `heartbeat` or `task` for a run the dashboard hasn't
seen (it started before the dashboard did) creates the run. Every event
command prints nothing and exits 0, whatever happens.

## Over Tailscale instead of a tunnel

If both machines are on your tailnet, skip ngrok and listen on the
dashboard's Tailscale address:

```sh
BOT_OPS_LISTEN=100.x.y.z:47800 bundle exec rake run
```

and on the bot machine `BOT_OPS_URL=http://100.x.y.z:47800`. The token is
still required, and still sent as Basic auth. Keep the port on the tailnet
only: events carry whatever detail a routine reports, over plain HTTP.

## What leaves the bot machine

Only what the routine (or the wrapper) puts in an event:

| Sent | Never sent |
| --- | --- |
| Bot name, team, run id, event name, routine name and title | The routine's full output |
| A task's name and a 160-character detail | Files, environment variables, the token file |
| The run's result or error: one line, 300 characters | Anything from chat with the bot |
| A timestamp | Token counts (bots don't report any) |

Legal bots may put client and matter details in results and errors; the
dashboard applies no redaction beyond those lengths, so write routines'
last lines accordingly. The dashboard stores the events only on your
machine.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| The curl check gives `404` with body `not found` | The tunnel's policy predates `/v1/bot-event`. Run `rake ngrok:policy` and restart the tunnel. |
| `404` with body `bot events not enabled` | The dashboard is older than the Bots page, or the collector isn't the one you think. |
| `401` | The token differs from `~/.config/bot-ops-blue/token` on the dashboard machine, or the header isn't `Basic botops:<token>`. |
| `422 not a bot event` | The body is missing `bot`, `run_id` or `bot_event`, or `bot_event` isn't one of `run_start heartbeat task task_error run_end run_error`. |
| Runs appear, then turn stale while still running | Heartbeats aren't arriving: the wrapper's process was killed with the routine, or `BOT_OPS_HEARTBEAT_S` is over 300. |
| A run shows twice | Two wrappers with different run ids. Wrap the routine once, at the outermost command. |
| Nothing appears, but the curl check works | The cron or timer environment has no `BOT_OPS_URL` or token (see step 3). Run the wrapper by hand from the same user first. |
| Events arrive late, all at once | They were spooled while the tunnel was down and flushed by the next successful post. Expected. |
