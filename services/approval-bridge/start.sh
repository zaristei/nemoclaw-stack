#!/usr/bin/env bash
# Start the approval bridge as a native Python process.
#
# Usage:
#   ./services/approval-bridge/start.sh        # start in foreground
#   ./services/approval-bridge/start.sh --bg   # start in background
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_ROOT="${STACK_ROOT:-/Volumes/macmini1}"
VENV="${STACK_ROOT}/venv/approval-bridge"
PID_FILE="${STACK_ROOT}/state/approval-bridge.pid"
LOG_FILE="${STACK_ROOT}/logs/approval-bridge.log"
ENV_FILE="${SCRIPT_DIR}/../../.env"

if [[ ! -d "$VENV" ]]; then
    echo "▶ Creating approval-bridge venv..."
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"
fi

set -a; source "$ENV_FILE"; set +a

if [[ "${1:-}" == "--bg" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"
    nohup "$VENV/bin/python" "$SCRIPT_DIR/main.py" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    echo "▶ Approval bridge started (pid $!, log: $LOG_FILE)"
else
    exec "$VENV/bin/python" "$SCRIPT_DIR/main.py"
fi
