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
URL), and notification text. File contents and tool output are never sent.

Standard library only (Python 3.6+).
"""
import base64
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


def session_title(transcript, session_id):
    """The session's title: the latest name it was given by hand (custom-title),
    else the latest generated one (ai-title), as the claude.ai sidebar shows.
    Reads only what was appended since the previous event (offset cached)."""
    if not transcript or not os.path.isfile(transcript):
        return None
    cache = os.path.join(TITLE_CACHE, "".join(c for c in session_id if c.isalnum() or c in "-_") + ".json")
    try:
        with open(cache) as f:
            state = json.load(f)
    except Exception:
        state = {}
    offset = state.get("offset", 0)
    if os.path.getsize(transcript) < offset:
        offset, state = 0, {}
    with open(transcript, "rb") as f:
        f.seek(offset)
        for line in f:
            if not line.endswith(b"\n"):
                break  # partial line; read it next time
            offset += len(line)
            if b"-title" not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") == "custom-title" and rec.get("customTitle"):
                state["custom"] = rec["customTitle"]
            elif rec.get("type") == "ai-title" and rec.get("aiTitle"):
                state["ai"] = rec["aiTitle"]
    state["offset"] = offset
    try:
        os.makedirs(TITLE_CACHE, exist_ok=True)
        with open(cache, "w") as f:
            json.dump(state, f)
    except OSError:
        pass
    title = state.get("custom") or state.get("ai")
    return title.strip()[:120] if title else None


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
            title = session_title(payload.get("transcript_path"), ev["session_id"])
            if title:
                ev["title"] = title
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
