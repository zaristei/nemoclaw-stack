#!/usr/bin/env bash
# Install the mediator-tools OpenClaw plugin into a running sandbox.
#
# For local dev only — in production the plugin is baked into the Docker
# image via the NemoClaw Dockerfile. This script:
#   1. Uploads the plugin files via base64 + exec (openshell upload drops JS)
#   2. Patches openclaw.json via kubectl exec as root
#   3. Restarts the pod via kubectl delete (k3s auto-recreates with PVC intact)
#   4. Restarts the mediator daemon (killed by pod restart)
#
# Usage:
#   ./scripts/install-mediator-plugin.sh
#   SANDBOX_NAME=my-sandbox ./scripts/install-mediator-plugin.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"

# Source stack env for PATH + DOCKER_HOST + XDG_CONFIG_HOME
eval "$("${SCRIPT_DIR}/stack.sh" env 2>/dev/null)" || true
export PATH="${CARGO_TARGET_DIR:-/Volumes/macmini1/nemoclaw-stack/build/openshell/target}/release:${PATH}"

# Resolve plugin source — prefer standalone repo, fall back to submodule
PLUGIN_SRC="${SCRIPT_DIR}/../NemoClaw/mediator-tools"
[[ -d "$PLUGIN_SRC/src" ]] || PLUGIN_SRC="${SCRIPT_DIR}/nemoclaw/mediator-tools"
[[ -d "$PLUGIN_SRC/src" ]] || { echo "error: mediator-tools source not found" >&2; exit 1; }

# Build if needed
if [[ ! -f "$PLUGIN_SRC/dist/index.js" ]]; then
    echo "Building mediator-tools plugin..."
    (cd "$PLUGIN_SRC" && npm install && npx tsc)
fi

echo "Installing mediator-tools plugin into sandbox '$SANDBOX_NAME'..."

# 1. Upload plugin files via base64
EXT_DIR="/sandbox/.openclaw-data/extensions/mediator-tools"
openshell sandbox exec -n "$SANDBOX_NAME" -- mkdir -p "${EXT_DIR}/dist" 2>/dev/null || true

# Compiled JS (for plugins.load.paths discovery)
b64=$(base64 -i "$PLUGIN_SRC/dist/index.js" | tr -d '\n')
openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c "echo $b64 | base64 -d > ${EXT_DIR}/dist/index.js"

# TypeScript source (for stock-plugin discovery if placed in stock dir)
b64=$(base64 -i "$PLUGIN_SRC/src/index.ts" | tr -d '\n')
openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c "echo $b64 | base64 -d > ${EXT_DIR}/index.ts"

echo "  Plugin files uploaded"

# 2. Write manifest + patch config via kubectl (needs root for config write)
COLIMA_HOME="${COLIMA_HOME:-/Volumes/macmini1/nemoclaw-stack/colima}"
DOCKER_HOST="unix://${COLIMA_HOME}/default/docker.sock"
export DOCKER_HOST

docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$SANDBOX_NAME" -- python3 -c "
import json
base = '${EXT_DIR}'
with open(f'{base}/openclaw.plugin.json', 'w') as f:
    json.dump({'id': 'mediator-tools', 'name': 'Mediator Syscall Tools', 'version': '0.1.0', 'enabledByDefault': True, 'configSchema': {'type': 'object', 'additionalProperties': False}}, f, indent=2)
cfg = json.load(open('/sandbox/.openclaw/openclaw.json'))
cfg.setdefault('plugins', {})['load'] = {'paths': [base]}
json.dump(cfg, open('/sandbox/.openclaw/openclaw.json', 'w'), indent=2)
print('  Config patched')
"

# 3. Restart pod (k3s auto-recreates with PVC intact — preserves files + config)
echo "  Restarting sandbox pod..."
docker exec openshell-cluster-nemoclaw kubectl delete pod -n openshell "$SANDBOX_NAME" 2>/dev/null
sleep 30

# 4. Restart mediator daemon (killed by pod restart)
echo "  Starting mediator daemon..."
openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c 'rm -f /sandbox/.mediator/mediator.db /sandbox/.mediator/mediator.sock /sandbox/.mediator/mediator.sock.token; nohup /sandbox/mediator-daemon --socket /sandbox/.mediator/mediator.sock --db "sqlite:///sandbox/.mediator/mediator.db?mode=rwc" --token-file /sandbox/.mediator/mediator.sock.token --approval-bridge-url http://host.docker.internal:8090 > /sandbox/.mediator/daemon.log 2>&1 & sleep 2; [ -S /sandbox/.mediator/mediator.sock ] && echo "  Mediator daemon ready" || echo "  Mediator daemon failed"'

# 5. Refresh env vars (new daemon = new token)
openshell sandbox exec -n "$SANDBOX_NAME" -- sh -c 'token=$(cat /sandbox/.mediator/mediator.sock.token 2>/dev/null || echo ""); for rc in /sandbox/.bashrc /sandbox/.profile; do sed -i "/MEDIATOR_TOKEN/d" "$rc" 2>/dev/null; printf "export MEDIATOR_TOKEN=%s\n" "$token" >> "$rc"; done'

echo "Done. Verify with: ./stack.sh run openshell sandbox exec -n $SANDBOX_NAME -- openclaw plugins list | grep mediator"
