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

Without BOT_OPS_URL it does nothing, so the hook is harmless in local
sessions and for anyone else who clones the repo. It never prints (stdout
from some hooks is fed back to Claude), always exits 0, and sends from a
forked background process so a session never waits on the network.

Only these fields leave the session: session id, event name, cwd, git
branch, model, a 300-character prompt excerpt, the tool name and a
160-character detail (command, file path, pattern or URL), and
notification text. File contents and tool output are never sent.

Standard library only (Python 3.6+).
"""
import base64
import json
import os
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


def trim(payload):
    ev = {k: payload[k] for k in PASS_THROUGH if isinstance(payload.get(k), str)}
    ev["at"] = time.time()
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


def main():
    url = os.environ.get("BOT_OPS_URL", "").rstrip("/")
    token = os.environ.get("BOT_OPS_TOKEN", "")
    if not url:
        return
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict) or not payload.get("session_id"):
        return
    body = json.dumps(trim(payload)).encode()
    if os.fork() != 0:
        return  # the hook returns at once; the child does the network call
    try:
        os.setsid()
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
