#!/usr/bin/env python3
"""Bot Ops Blue cloud reporter.

A Claude Code command hook for cloud sessions (claude.ai/code). Each hook
event is trimmed to what the dashboard shows and POSTed to its collector:

    BOT_OPS_URL    https://<your tunnel>   (an environment variable on the
                                           cloud environment)

The collector's token is NOT given to the session: store it as a network
secret on the environment (Bearer, allowed website = the tunnel's host), and
Anthropic's agent proxy adds the Authorization header after the request
leaves the session. Alternatively set BOT_OPS_TOKEN (visible to anyone
using the environment): it is sent as HTTP Basic auth, "botops:<token>",
which the ngrok edge and the collector both accept.

It only runs in cloud sessions: unless CLAUDE_CODE_REMOTE is "true" and
BOT_OPS_URL is set, it does nothing, so local sessions on the Mac or in VS
Code (which the dashboard already reads directly) never report twice.
Despite its name, CLAUDE_CODE_REMOTE is the cloud-session marker, not
Remote Control: Anthropic's cloud environment docs say the session VM's
environment carries it as "true" and it's never "true" locally. It never prints (stdout
from some hooks is fed back to Claude), always exits 0, and sends from a
forked background process so a session never waits on the network.

Only these fields leave the session: session id, event name, cwd, git
branch, model, the session's claude.ai URL, its title when the transcript
has one (cloud transcripts usually don't), a 300-character prompt excerpt,
the tool name and a 160-character detail (command, file path, pattern or
URL), notification text, and token counts (per hour and model, read from
the transcript's usage records, subagents included). File contents and
tool output are never sent.

Standard library only (Python 3.6+).
"""
import base64
import calendar
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

DETAIL_KEYS = ("command", "file_path", "pattern", "url", "query", "description", "skill")
PASS_THROUGH = ("session_id", "hook_event_name", "cwd", "source", "reason", "message",
                "notification_type", "tool_name", "model")


def one_line(text, limit):
    text = text.strip()
    return text.splitlines()[0][:limit] if text else ""


def session_url():
    """The session's page at claude.ai, from CLAUDE_CODE_REMOTE_SESSION_ID
    (Anthropic's docs: https://claude.ai/code/${ID/#cse_/session_})."""
    sid = os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", sid):
        return None
    return "https://claude.ai/code/" + re.sub(r"^cse_", "session_", sid)


def trim(payload):
    ev = {k: payload[k] for k in PASS_THROUGH if isinstance(payload.get(k), str)}
    ev["at"] = time.time()
    url = session_url()
    if url:
        ev["url"] = url
    if isinstance(payload.get("prompt"), str):
        ev["prompt"] = payload["prompt"].strip()[:300]
    tool_input = payload.get("tool_input")
    if isinstance(tool_input, dict):
        for key in DETAIL_KEYS:
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                ev["detail"] = one_line(value, 160)
                break
    response = payload.get("tool_response")
    if isinstance(response, dict) and (response.get("is_error") or response.get("error")):
        ev["error"] = True
    if ev.get("hook_event_name") == "SessionStart" and ev.get("cwd"):
        try:
            branch = subprocess.run(["git", "-C", ev["cwd"], "rev-parse", "--abbrev-ref", "HEAD"],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2)
            ev["branch"] = branch.stdout.decode().strip()
        except Exception:
            pass
    return ev


TITLE_CACHE = os.path.expanduser("~/.cache/bot-ops-blue")
TOKEN_KEYS = (("output_tokens", 0), ("input_tokens", 1), ("cache_read_input_tokens", 2),
              ("cache_creation_input_tokens", 3))
KEEP_HOURS = 48


def read_new(path, state, on_record):
    """Calls on_record for each whole JSON line appended to `path` since the
    offset kept in state["files"]; a file that shrank is read again."""
    offsets = state.setdefault("files", {})
    offset = offsets.get(path, 0)
    if os.path.getsize(path) < offset:
        offset = 0
    with open(path, "rb") as f:
        f.seek(offset)
        for line in f:
            if not line.endswith(b"\n"):
                break  # partial line; read it next time
            offset += len(line)
            if b"-title" in line or b'"usage"' in line:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict):
                    on_record(rec, path)
    offsets[path] = offset


def scan_transcript(transcript, session_id):
    """Reads what the session's transcript (and its subagents' transcripts)
    gained since the previous event: the session's title, the latest name
    given by hand (custom-title) else the generated one (ai-title), as the
    claude.ai sidebar shows; and token usage, summed per hour and model.
    Returns (title, usage rows for the hours that changed, session token
    totals, context size). State is cached between events."""
    if not transcript or not os.path.isfile(transcript):
        return None, [], None, None
    cache = os.path.join(TITLE_CACHE, "".join(c for c in session_id if c.isalnum() or c in "-_") + ".json")
    try:
        with open(cache) as f:
            state = json.load(f)
    except Exception:
        state = {}
    if "files" not in state:
        state = {}  # a cache from before token counts: read everything again
    hours = state.setdefault("hours", {})     # "hour|model" -> [out, in, cache_read, cache_write]
    totals = state.setdefault("tokens", [0, 0, 0, 0])
    last_id = state.setdefault("last_id", {})  # per file: a message's blocks repeat its usage
    changed = set()

    def on_record(rec, path):
        if rec.get("type") == "custom-title" and rec.get("customTitle"):
            state["custom"] = rec["customTitle"]
        elif rec.get("type") == "ai-title" and rec.get("aiTitle"):
            state["ai"] = rec["aiTitle"]
        msg = rec.get("message")
        if rec.get("type") != "assistant" or not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
            return
        mid = msg.get("id")
        if mid and last_id.get(path) == mid:
            return
        last_id[path] = mid
        usage = msg["usage"]
        try:
            stamp = calendar.timegm(time.strptime(rec.get("timestamp", "")[:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            stamp = time.time()
        key = "%d|%s" % (int(stamp) // 3600 * 3600, msg.get("model") or "")
        row = hours.setdefault(key, [0, 0, 0, 0])
        for name, i in TOKEN_KEYS:
            n = usage.get(name)
            if isinstance(n, int):
                row[i] += n
                totals[i] += n
        if path == transcript:
            state["context"] = sum(usage.get(k) or 0 for k in ("input_tokens", "cache_read_input_tokens",
                                                                  "cache_creation_input_tokens"))
        changed.add(key)

    read_new(transcript, state, on_record)
    subagents = os.path.join(transcript[:-len(".jsonl")], "subagents")
    if transcript.endswith(".jsonl") and os.path.isdir(subagents):
        for name in sorted(os.listdir(subagents)):
            if name.endswith(".jsonl"):
                read_new(os.path.join(subagents, name), state, on_record)

    oldest = int(time.time()) // 3600 * 3600 - KEEP_HOURS * 3600
    for key in [k for k in hours if int(k.split("|")[0]) < oldest]:
        del hours[key]
    try:
        os.makedirs(TITLE_CACHE, exist_ok=True)
        tmp = cache + ".tmp%d" % os.getpid()
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, cache)  # concurrent hooks: each writes a whole, consistent state
    except OSError:
        pass
    title = state.get("custom") or state.get("ai")
    rows = [[int(k.split("|")[0]), k.split("|", 1)[1]] + hours[k] for k in sorted(changed) if k in hours]
    tokens = dict(zip(("out", "in", "cache_read", "cache_write"), totals))
    return (title.strip()[:120] if title else None), rows, tokens, state.get("context")


def main():
    url = os.environ.get("BOT_OPS_URL", "").rstrip("/")
    token = os.environ.get("BOT_OPS_TOKEN", "")
    if os.environ.get("CLAUDE_CODE_REMOTE") != "true" or not url:
        return
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict) or not payload.get("session_id"):
        return
    ev = trim(payload)
    if os.fork() != 0:
        return  # the hook returns at once; the child does the rest
    try:
        os.setsid()
        try:
            title, usage, tokens, context = scan_transcript(payload.get("transcript_path"), ev["session_id"])
            if title:
                ev["title"] = title
            if usage:
                ev["usage"] = usage  # [[hour, model, out, in, cache_read, cache_write], ...] running totals
            if tokens and any(tokens.values()):
                ev["tokens"] = tokens
            if context:
                ev["context"] = context
        except Exception:
            pass
        body = json.dumps(ev).encode()
        headers = {"Content-Type": "application/json", "ngrok-skip-browser-warning": "1"}
        if token:  # Basic, because the ngrok edge's basic-auth checks it first
            headers["Authorization"] = "Basic " + base64.b64encode(("botops:" + token).encode()).decode()
        req = urllib.request.Request(url + "/v1/event", data=body, method="POST", headers=headers)
        urllib.request.urlopen(req, timeout=5).read()
    except Exception:
        pass
    os._exit(0)


try:
    main()
except Exception:
    pass
sys.exit(0)
