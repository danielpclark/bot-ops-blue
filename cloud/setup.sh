#!/bin/bash
# Bot Ops Blue: cloud environment setup script (alternative to committing the
# hook into each repo). Paste into your claude.ai/code environment's setup
# script. It installs cloud/bot-ops-report.py as a user-level hook inside the
# cloud machine, so every repo's sessions report. Needs BOT_OPS_URL and
# BOT_OPS_TOKEN set as environment variables on the same environment.
set -euo pipefail
mkdir -p ~/.claude/hooks
curl -fsSL https://raw.githubusercontent.com/danielpclark/bot-ops-blue/main/cloud/bot-ops-report.py \
  -o ~/.claude/hooks/bot-ops-report.py
python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
settings = json.load(open(path)) if os.path.exists(path) else {}
cmd = 'test -n "$BOT_OPS_URL" && python3 "$HOME/.claude/hooks/bot-ops-report.py" || true'
hooks = settings.setdefault("hooks", {})
for event in ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]:
    groups = hooks.setdefault(event, [])
    if not any(h.get("command") == cmd for g in groups for h in g.get("hooks", [])):
        entry = {"hooks": [{"type": "command", "command": cmd, "timeout": 5}]}
        if event == "PostToolUse":
            entry["matcher"] = "*"
        groups.append(entry)
json.dump(settings, open(path, "w"), indent=2)
PY
