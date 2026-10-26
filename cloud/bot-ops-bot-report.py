#!/usr/bin/env python3
"""Bot Ops Blue bot reporter.

Reports an assistant bot's scheduled routine runs to the dashboard, so they
show on its Bots page next to Claude Code sessions. Each run POSTs a few
small JSON events to the collector:

    BOT_OPS_URL         https://<your tunnel>  (or http://<dashboard>:47800
                                                over Tailscale)
    BOT_OPS_TOKEN       the collector token; else the file named by
                        BOT_OPS_TOKEN_FILE, else ~/.config/bot-ops-blue/bot-token

The token is sent as HTTP Basic auth, "botops:<token>", which the ngrok
edge and the collector both accept. Without a URL or a token the reporter
does nothing (a wrapped command still runs).

The simplest use wraps the routine's command: it sends run_start, a
heartbeat every minute while the command runs, then run_end with the last
line the command printed, or run_error with its last line of stderr, and
exits with the command's own exit code:

    bot-ops-bot-report.py wrap --bot "Bot Ops" --routine nightly-digest -- python3 digest.py

A routine that wants finer detail sends the events itself (run_start,
heartbeat, task, run_end, run_error; see --help). Event mode never prints
and always exits 0, so a reporting problem can never break a routine.

A POST that fails is spooled to ~/.cache/bot-ops-blue/bot-spool.jsonl and
sent, as one batch, after the next one that succeeds; spooled events older
than 24 hours are dropped, as the dashboard would drop them anyway.

Only these fields are sent: the bot's name and team, the run id, the event
name, the routine's name and title, a task's name, a 160-character detail,
the run's result or error (300 characters) and a timestamp. Nothing is
read from the routine beyond the last line of its output.

Standard library only (Python 3.6+).
"""
import argparse
import base64
import json
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

SPOOL = os.path.expanduser("~/.cache/bot-ops-blue/bot-spool.jsonl")
TOKEN_FILE = os.path.expanduser("~/.config/bot-ops-blue/bot-token")
KEEP_S = 24 * 3600
TIMEOUT_S = 5


def config():
    """(url, token), or None when the reporter has nothing to send to."""
    url = os.environ.get("BOT_OPS_URL", "").rstrip("/")
    token = os.environ.get("BOT_OPS_TOKEN", "")
    if not token:
        path = os.environ.get("BOT_OPS_TOKEN_FILE") or TOKEN_FILE
        try:
            with open(path) as f:
                token = f.read().strip()
        except OSError:
            token = ""
    if not url or not token:
        return None
    return url, token


def post(cfg, body):
    """POSTs one JSON body; the HTTP status, or None when it never got through."""
    url, token = cfg
    headers = {"Content-Type": "application/json", "ngrok-skip-browser-warning": "1",
               "Authorization": "Basic " + base64.b64encode(("botops:" + token).encode()).decode()}
    req = urllib.request.Request(url + "/v1/bot-event", data=body, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as res:
            res.read()
            return res.getcode()
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return None


def spool(body):
    try:
        os.makedirs(os.path.dirname(SPOOL), exist_ok=True)
        fd = os.open(SPOOL, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "ab") as f:
            f.write(body + b"\n")
    except OSError:
        pass


def flush_spool(cfg):
    """Sends what earlier runs could not, as one batch, and empties the spool
    once the collector has taken it."""
    try:
        with open(SPOOL, "rb") as f:
            lines = f.read().splitlines()
    except OSError:
        return
    cutoff = time.time() - KEEP_S
    events = []
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and isinstance(ev.get("at"), (int, float)) and ev["at"] >= cutoff:
            events.append(ev)
    if not events:
        status = 204
    else:
        status = post(cfg, json.dumps({"events": events}).encode())
    if status is not None and 200 <= status < 300:
        try:
            with open(SPOOL, "wb"):
                pass
        except OSError:
            pass


def send(cfg, ev):
    """One event, now; spooled if the dashboard can't be reached."""
    if cfg is None:
        return
    ev = {k: v for k, v in ev.items() if v is not None}
    ev["at"] = time.time()
    body = json.dumps(ev).encode()
    status = post(cfg, body)
    if status is not None and 200 <= status < 300:
        flush_spool(cfg)
    elif status is None or status >= 500:
        spool(body)
    # a 4xx is the collector refusing this event; sending it again won't help


def event(args, name, **fields):
    ev = {"bot": args.bot, "bot_event": name, "run_id": args.run}
    ev.update(fields)
    return ev


def tee(stream, out, last):
    """Copies `stream` to `out` line by line, remembering the last line that
    wasn't blank in last[0]."""
    for line in iter(stream.readline, b""):
        try:
            out.write(line)
            out.flush()
        except (OSError, ValueError):
            pass
        text = line.decode("utf-8", "replace").strip()
        if text:
            last[0] = text


def wrap(args, cfg):
    """Runs the routine's command, reporting around it. Returns its exit code."""
    args.run = "r_" + secrets.token_hex(6)
    send(cfg, event(args, "run_start", routine=args.routine, title=args.title, team=args.team))
    stop = threading.Event()
    try:
        interval = float(os.environ.get("BOT_OPS_HEARTBEAT_S", "60"))
    except ValueError:
        interval = 60.0

    def beat():
        while not stop.wait(interval):
            send(cfg, event(args, "heartbeat"))

    if cfg is not None:
        threading.Thread(target=beat, daemon=True).start()
    out, err = [""], [""]
    try:
        proc = subprocess.Popen(args.cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        stop.set()
        send(cfg, event(args, "run_error", error=("%s: %s" % (args.cmd[0], e.strerror))[:300]))
        sys.stderr.write("bot-ops-bot-report: %s: %s\n" % (args.cmd[0], e.strerror))
        return 127
    readers = [threading.Thread(target=tee, args=(proc.stdout, sys.stdout.buffer, out)),
               threading.Thread(target=tee, args=(proc.stderr, sys.stderr.buffer, err))]
    for t in readers:
        t.start()
    code = proc.wait()
    for t in readers:
        t.join()
    stop.set()
    if code == 0:
        send(cfg, event(args, "run_end", result=out[0][:300] or None))
    else:
        send(cfg, event(args, "run_error", error=(err[0] or "exit %d" % code)[:300]))
    return code


def parser():
    p = argparse.ArgumentParser(description="Report an assistant bot's routine runs to Bot Ops Blue.")
    sub = p.add_subparsers(dest="command", metavar="command")
    sub.required = True

    def common(sp, run=True):
        sp.add_argument("--bot", required=True, help="the bot's name, as the dashboard shows it")
        if run:
            sp.add_argument("--run", required=True, help="the run's id ([A-Za-z0-9_-], up to 128)")

    s = sub.add_parser("run_start", help="a scheduled routine run began")
    common(s)
    s.add_argument("--routine", required=True)
    s.add_argument("--title")
    s.add_argument("--team")
    common(sub.add_parser("heartbeat", help="the run is still going (send one a minute)"))
    s = sub.add_parser("task", help="the run did one step")
    common(s)
    s.add_argument("--task", required=True, help="the step's name (a tool, a stage)")
    s.add_argument("--detail")
    s.add_argument("--error", help="what went wrong, when the step failed")
    s = sub.add_parser("run_end", help="the run finished")
    common(s)
    s.add_argument("--result", help="one line on what it produced")
    s = sub.add_parser("run_error", help="the run failed")
    common(s)
    s.add_argument("--error", required=True)
    s = sub.add_parser("wrap", help="run a command as one routine run: start, heartbeats, end or error")
    common(s, run=False)
    s.add_argument("--routine", required=True)
    s.add_argument("--title")
    s.add_argument("--team")
    s.add_argument("cmd", nargs=argparse.REMAINDER, metavar="-- CMD...")
    return p


def main(argv):
    args = parser().parse_args(argv)
    cfg = config()
    if args.command == "wrap":
        if args.cmd and args.cmd[0] == "--":
            args.cmd = args.cmd[1:]
        if not args.cmd:
            parser().error("wrap needs a command after --")
        return wrap(args, cfg)
    if cfg is None:
        return 0
    if args.command == "run_start":
        send(cfg, event(args, "run_start", routine=args.routine, title=args.title, team=args.team))
    elif args.command == "heartbeat":
        send(cfg, event(args, "heartbeat"))
    elif args.command == "task":
        send(cfg, event(args, "task", task=args.task, detail=args.detail, error=args.error))
    elif args.command == "run_end":
        send(cfg, event(args, "run_end", result=args.result))
    elif args.command == "run_error":
        send(cfg, event(args, "run_error", error=args.error))
    return 0


if __name__ == "__main__":
    wrapping = len(sys.argv) > 1 and sys.argv[1] == "wrap"
    try:
        code = main(sys.argv[1:])
    except SystemExit as e:  # argparse: its message is already on stderr
        code = e.code if wrapping else 0
    except Exception:
        code = 1 if wrapping else 0
    sys.exit(code if wrapping else 0)
