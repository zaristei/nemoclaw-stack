#!/usr/bin/env bash
# Tear down the nemoclaw-stack: sandbox, gateway, LiteLLM, Colima, state.
#
# Usage:
#   ./teardown.sh           # stop everything, keep state
#   ./teardown.sh --clean   # stop everything and wipe state dirs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export STACK_ROOT="${STACK_ROOT:-/Volumes/macmini1}"
STACK_DATA="${STACK_ROOT}/nemoclaw-stack"
export COLIMA_HOME="${STACK_DATA}/colima"
export DOCKER_HOST="unix://${COLIMA_HOME}/default/docker.sock"
export XDG_CONFIG_HOME="${STACK_DATA}/config"
export PATH="${STACK_DATA}/build/openshell/target/release:${PATH}"

LITELLM_PID="${STACK_DATA}/state/litellm.pid"
CLEAN=0
[[ "${1:-}" == "--clean" ]] && CLEAN=1

log() { echo "▶ $*"; }

# ── Fix SSH config (may have been created by another user) ────────────────────
rm -f "${COLIMA_HOME}/ssh_config" 2>/dev/null || true

# ── Port forwards ─────────────────────────────────────────────────────────────
# Stop openshell port forwards gracefully before deleting sandboxes
if command -v openshell &>/dev/null; then
    forwards=$(openshell forward list 2>/dev/null | awk 'NR>1 {print $1, $3}' || true)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        port=$(echo "$line" | awk '{print $1}')
        sandbox=$(echo "$line" | awk '{print $2}')
        log "Stopping forward ${port} → ${sandbox}..."
        openshell forward stop "$port" "$sandbox" 2>/dev/null || true
    done <<< "$forwards"
fi

# ── Sandboxes ─────────────────────────────────────────────────────────────────
if command -v openshell &>/dev/null && colima status &>/dev/null; then
    sandboxes=$(openshell sandbox list 2>/dev/null | awk 'NR>1 {print $1}' || true)
    for sb in $sandboxes; do
        log "Deleting sandbox ${sb}..."
        openshell sandbox delete "$sb" 2>/dev/null || true
    done
fi

# ── Gateway ───────────────────────────────────────────────────────────────────
if command -v openshell &>/dev/null && colima status &>/dev/null; then
    if openshell gateway info -g nemoclaw &>/dev/null; then
        log "Destroying gateway..."
        openshell gateway destroy -g nemoclaw 2>/dev/null || true
    fi
fi

# ── Approval Bridge ──────────────────────────────────────────────────────────
BRIDGE_PID="${STACK_DATA}/state/approval-bridge.pid"
if [[ -f "$BRIDGE_PID" ]]; then
    pid=$(cat "$BRIDGE_PID")
    if kill -0 "$pid" 2>/dev/null; then
        log "Stopping approval bridge (pid $pid)..."
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 6); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$BRIDGE_PID"
fi

# ── LiteLLM ──────────────────────────────────────────────────────────────────
if [[ -f "$LITELLM_PID" ]]; then
    pid=$(cat "$LITELLM_PID")
    if kill -0 "$pid" 2>/dev/null; then
        log "Stopping LiteLLM (pid $pid)..."
        kill "$pid" 2>/dev/null || true
        # Wait up to 5s for graceful shutdown
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        # Force kill if still alive
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$LITELLM_PID"
fi

# ── Orphaned openshell processes (from our build only) ────────────────────────
orphans=$(pgrep -f "${STACK_DATA}/(build/openshell|mise/installs)" 2>/dev/null || true)
if [[ -n "$orphans" ]]; then
    log "Cleaning up orphaned openshell processes..."
    echo "$orphans" | xargs kill -TERM 2>/dev/null || true
    sleep 1
    # Force kill any survivors
    for pid in $orphans; do
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done
fi

# ── Colima ────────────────────────────────────────────────────────────────────
if colima status &>/dev/null; then
    log "Stopping Colima..."
    colima stop
fi

# ── State cleanup ─────────────────────────────────────────────────────────────
if [[ "$CLEAN" -eq 1 ]]; then
    log "Wiping state dirs..."
    rm -rf "${STACK_DATA}/state"
    rm -rf "${STACK_DATA}/config"
    rm -rf "${STACK_DATA}/venv"
    log "State wiped."
fi

log "Done."
