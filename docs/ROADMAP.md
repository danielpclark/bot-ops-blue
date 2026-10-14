# Roadmap

Where Bot Ops Blue is headed, and what each step needs. Phases 1 and 2 are
implemented; Phase 4 is designed, not built. Contributions that fit a phase
are welcome; open an issue first for anything larger.

## What the data supports

| Source | What's available |
| --- | --- |
| Local sessions (the dashboard's own machine) | Everything in the transcripts: per-message tokens (input, output, cache read, cache write) and model, every tool call with its full input and its result time, tool errors, prompts, titles, git branch, context size. |
| Cloud sessions (claude.ai/code) | Hook events only: prompts, tool names with a short detail, notifications, session start and stop, the session's claude.ai link. **No token counts**: hooks don't receive usage. Claude Code's OpenTelemetry export could add them. |
| Other machines (`bin/bot-ops-agent`) | The same as local sessions, but with short excerpts instead of full text. |

## Phase 1: drill-downs (done)

Everything here reuses the detail overlay: click, read, Esc to close.

- **Header stats are clickable.**
  - **Output tokens:** by session, project, model and hour, with input, cache read and cache write next to output, and the cache-hit ratio.
  - **Tool calls:** by tool, with error rate and typical and slowest duration (from each call's start to its result).
  - **Prompts:** by project, with the most recent ones in full.
  - **Live sessions / Busy:** every session, its status and when it was last worked on.
- **Session timeline.** "Timeline" in Session Details lists the session's prompts, tool calls (with durations), errors and turns in order, with the context size after each prompt.
- **Project view.** Click a project for its sessions, branches, token totals and the files edited most.
- **Usage chart.**
  - Click an hour for that hour's breakdown.
  - Click a legend entry to hide or show a series.
  - Choose **12h / 24h / 7d / 30d**.
- **Context meter.** Session Details shows each session's context against its model's window, and warns near the limit.

## Phase 2: navigation, alerts, history (done)

- **"Needs you" alerts.** When a session waits for a permission, the Dock icon gets a badge with the number of waiting sessions and bounces once. A macOS notification is optional (Settings), because a script-posted notification opens Script Editor when clicked. Local sessions need the optional hook (`bin/bot-ops-hook`); cloud sessions report it already.
- **Search.** `/` opens a search over the event log, tool calls and prompts. Type to filter, Enter or a click to open a result.
- **Filters.** "This session only" in Tool Calls and the Event Log narrows them to the selected session.
- **Keyboard.**
  - Up and Down move through the sessions list.
  - Enter opens the selected session's timeline.
  - `/` opens search.
  - Esc closes whatever is open.
- **History beyond 24 hours.**
  - The probe keeps hourly totals for local transcripts from the last 7 days.
  - Every source's hourly totals are saved to `~/.config/bot-ops-blue/history.json` and kept for 30 days, so cloud and other-machine usage survives restarts and outlives the 24 hours they report.

## Phase 3: actions from the dashboard (not planned)

Opening a project in an editor, copying a resume command, opening transcripts. Not on the plan for now.

## Phase 4: web proxy for cloud sessions (designed, not built)

**Goal:** let commands in cloud sessions fetch sites that block Anthropic's datacenter address ranges, with the request leaving from the dashboard's machine instead.

**Shape:**
- A fetch relay on the collector, `GET /v1/proxy?url=…`, reached through the same ngrok tunnel and network secret as the event collector.
- A `bot-ops-fetch <url>` command installed on the cloud machine by the setup script.
- A line in that machine's `~/.claude/CLAUDE.md` telling Claude to use it when a site blocks it.

**Why not `HTTPS_PROXY`?** ngrok's HTTP endpoints don't carry `CONNECT`, and its TCP endpoints need a paid, verified account.

**Limits:**
- It only helps commands run on the cloud machine (curl, scripts, package fetches). Claude's built-in WebFetch and WebSearch run on Anthropic's servers and aren't affected.
- ngrok's free plan caps bandwidth.

**Security (required before it ships):**
- **Off by default**, enabled separately from the event collector.
- **The local network is unreachable.** Refuse loopback, private, link-local and unique-local ranges, and their IPv6 equivalents, after DNS resolution, and again on every redirect. This blocks the agent from probing your LAN through your machine.
- **A domain allowlist**, recommended over allow-all: a prompt-injected session could otherwise send requests from your IP anywhere.
- **Limited requests:** GET and HEAD only to start; response-size and time limits; a per-minute rate limit; no cookies forwarded; credential headers stripped.
- **Visible and stoppable:** every proxied request appears in the dashboard's event log, and the Settings page has a kill switch.

**Policy:** sites that block datacenter traffic do so deliberately. Use the relay only for sites you're permitted to access. Requests carry your IP's reputation and are attributable to you.
