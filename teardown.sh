#!/usr/bin/env bash
# Tear down the nemoclaw-stack: sandbox, gateway, compose services, Colima, state.
#
# Usage:
#   ./teardown.sh           # stop everything, keep state
#   ./teardown.sh --clean   # stop everything and wipe state dirs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export STACK_ROOT="${STACK_ROOT:-/Volumes/macmini1}"
export COLIMA_HOME="${STACK_ROOT}/config/colima"
export DOCKER_HOST="unix://${COLIMA_HOME}/default/docker.sock"
export XDG_CONFIG_HOME="${STACK_ROOT}/config"
export PATH="${STACK_ROOT}/build/openshell/target/release:${PATH}"

COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yml"
CLEAN=0
[[ "${1:-}" == "--clean" ]] && CLEAN=1

log() { echo "▶ $*"; }

# ── Sandbox ───────────────────────────────────────────────────────────────────
if command -v openshell &>/dev/null && colima status &>/dev/null; then
    sandboxes=$(openshell sandbox list --output json 2>/dev/null | python3 -c "
import sys, json
for s in json.loads(sys.stdin.read()):
    print(s['name'])
" 2>/dev/null || true)

    for sb in $sandboxes; do
        log "Deleting sandbox ${sb}..."
        openshell sandbox delete "$sb" 2>/dev/null || true
    done
fi

# ── Gateway ───────────────────────────────────────────────────────────────────
if colima status &>/dev/null; then
    if docker ps -q --filter name=openshell-cluster-nemoclaw &>/dev/null; then
        log "Stopping gateway..."
        docker stop openshell-cluster-nemoclaw 2>/dev/null || true
        docker rm openshell-cluster-nemoclaw 2>/dev/null || true
    fi

    # ── Compose ───────────────────────────────────────────────────────────────
    log "Stopping compose services..."
    $COMPOSE down 2>/dev/null || true
fi

# ── Colima ────────────────────────────────────────────────────────────────────
if colima status &>/dev/null; then
    log "Stopping Colima..."
    colima stop
fi

# ── State cleanup ─────────────────────────────────────────────────────────────
if [[ "$CLEAN" -eq 1 ]]; then
    log "Wiping state dirs..."
    rm -rf "${STACK_ROOT}/state/nemoclaw"
    rm -rf "${STACK_ROOT}/config/openshell"
    log "State wiped."
fi

log "Done."
