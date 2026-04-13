#!/usr/bin/env python3
"""Add the mediator-tools plugin to OpenClaw's config."""
import json, sys

config_path = "/sandbox/.openclaw/openclaw.json"
plugin_path = "/sandbox/.openclaw-data/extensions/mediator-tools"

with open(config_path) as f:
    cfg = json.load(f)

cfg.setdefault("plugins", {})
cfg["plugins"]["enabled"] = True
cfg["plugins"].setdefault("load", {})
paths = cfg["plugins"]["load"].get("paths", [])
if plugin_path not in paths:
    paths.append(plugin_path)
cfg["plugins"]["load"]["paths"] = paths
allow = cfg["plugins"].get("allow", [])
if "mediator-tools" not in allow:
    allow.append("mediator-tools")
cfg["plugins"]["allow"] = allow

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)

print(json.dumps(cfg.get("plugins", {}), indent=2))
