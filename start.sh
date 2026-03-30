#!/usr/bin/env bash
# Start nemoclaw-stack: build local OpenShell, install NemoClaw deps, boot services,
# and onboard NemoClaw.
#
# Usage:
#   ./start.sh                        # build + start + onboard
#   ./start.sh ps                     # show status
#   ./start.sh --secrets keychain     # use macOS Keychain for API keys
#
# Environment:
#   STACK_ROOT              Storage root (default: /Volumes/macmini1)
#   NEMOCLAW_MODEL          Model for NemoClaw inference (default: tier-haiku-sensitive)
#   NEMOCLAW_ENDPOINT       LiteLLM endpoint URL (default: http://host.docker.internal:4000/v1)
#   NEMOCLAW_SANDBOX_NAME   Sandbox name (default: my-assistant)
#   NEMOCLAW_POLICY_MODE    Policy preset mode: suggested, custom, skip (default: suggested)
#   NEMOCLAW_POLICY_PRESETS Comma-separated preset names (used with NEMOCLAW_POLICY_MODE=custom)
#   SECRETS_BACKEND         Secrets backend: env, keychain (default: env, or set via --secrets)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Storage root — all state, build artifacts, and tool installs land here ──
export STACK_ROOT="${STACK_ROOT:-/Volumes/macmini1}"
STACK_DATA="${STACK_ROOT}/nemoclaw-stack"
mkdir -p "$STACK_DATA"

# ── Paths ────────────────────────────────────────────────────────────────────
export COLIMA_HOME="${STACK_DATA}/colima"
export DOCKER_HOST="unix://${COLIMA_HOME}/default/docker.sock"
export XDG_CONFIG_HOME="${STACK_DATA}/config"        # OpenShell state (kubeconfig, etc.)
export NEMOCLAW_HOME="${STACK_DATA}/state/nemoclaw"   # NemoClaw state (~/.nemoclaw)
export CARGO_TARGET_DIR="${STACK_DATA}/build/openshell/target"  # Rust build artifacts
export MISE_DATA_DIR="${STACK_DATA}/mise"             # mise tool installs
export OPENSHELL_CLUSTER_IMAGE="openshell/cluster:local"

OPENSHELL_DIR="${SCRIPT_DIR}/openshell"
NEMOCLAW_DIR="${SCRIPT_DIR}/nemoclaw"
LITELLM_VENV="${STACK_DATA}/venv/litellm"
LITELLM_PID="${STACK_DATA}/state/litellm.pid"
LITELLM_LOG="${STACK_DATA}/logs/litellm.log"
LITELLM_CONFIG="${SCRIPT_DIR}/services/litellm/config/litellm_config.built.yaml"

log() { echo "▶ $*"; }

# ── CLI args ─────────────────────────────────────────────────────────────────
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --secrets)
            export SECRETS_BACKEND="${2:?--secrets requires a value (env, keychain)}"
            shift 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

# ── Status check ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "ps" ]]; then
    echo "Colima:    $(colima status 2>&1 | grep -o 'running\|not running' || echo 'not running')"
    echo "Gateway:   $(docker ps --format '{{.Status}}' --filter name=openshell-cluster-nemoclaw 2>/dev/null || echo 'not running')"
    if [[ -f "$LITELLM_PID" ]] && kill -0 "$(cat "$LITELLM_PID")" 2>/dev/null; then
        echo "LiteLLM:   running (pid $(cat "$LITELLM_PID"))"
    else
        echo "LiteLLM:   not running"
    fi
    echo "Sandbox:   $(PATH="${CARGO_TARGET_DIR}/release:${PATH}" openshell sandbox list 2>/dev/null | tail -n +2 || echo 'none')"
    exit 0
fi

# ── Colima ────────────────────────────────────────────────────────────────────
# Remove stale ssh_config before start — Colima regenerates it as the current
# user, but SSH rejects files owned by a different user.
rm -f "${COLIMA_HOME}/ssh_config" 2>/dev/null || true
if ! colima status &>/dev/null; then
    log "Starting Colima..."
    colima start
fi
chmod 644 "${COLIMA_HOME}/ssh_config" 2>/dev/null || true

# ── LiteLLM config ────────────────────────────────────────────────────────────
BUILT="${LITELLM_CONFIG}"
if [[ ! -f "$BUILT" ]] || \
   [[ "${SCRIPT_DIR}/services/litellm/config/models.yaml" -nt "$BUILT" ]] || \
   [[ "${SCRIPT_DIR}/services/litellm/config/litellm_config.yaml" -nt "$BUILT" ]] || \
   [[ "${SCRIPT_DIR}/services/litellm/config/trusted_providers.yaml" -nt "$BUILT" ]]; then
    log "Rebuilding LiteLLM config..."
    python3 "${SCRIPT_DIR}/scripts/build_litellm_config.py"
fi

# ── LiteLLM: install + run as native process ─────────────────────────────────
if [[ ! -d "$LITELLM_VENV" ]]; then
    log "Creating LiteLLM venv..."
    python3 -m venv "$LITELLM_VENV"
    "$LITELLM_VENV/bin/pip" install --quiet 'litellm[proxy]'
fi

if [[ -f "$LITELLM_PID" ]] && kill -0 "$(cat "$LITELLM_PID")" 2>/dev/null; then
    log "LiteLLM already running (pid $(cat "$LITELLM_PID"))"
else
    log "Starting LiteLLM proxy..."
    mkdir -p "$(dirname "$LITELLM_LOG")" "$(dirname "$LITELLM_PID")"
    source "${SCRIPT_DIR}/scripts/resolve-secrets.sh"
    nohup "$LITELLM_VENV/bin/litellm" \
        --config "$LITELLM_CONFIG" \
        --port 4000 \
        > "$LITELLM_LOG" 2>&1 &
    echo $! > "$LITELLM_PID"
    log "LiteLLM started (pid $!, log: $LITELLM_LOG)"
fi

# ── OpenShell: build CLI binary ───────────────────────────────────────────────
log "Building OpenShell CLI (incremental)..."
(
    cd "${OPENSHELL_DIR}"
    mise trust mise.toml &>/dev/null || true
    mise exec -- cargo build --release -p openshell-cli
)

# Prepend built binary to PATH for this session and any child processes
export PATH="${CARGO_TARGET_DIR}/release:${PATH}"

# ── OpenShell: build cluster image ────────────────────────────────────────────
log "Building OpenShell cluster image (cached)..."
(
    cd "${OPENSHELL_DIR}"
    IMAGE_TAG=local mise exec -- ./tasks/scripts/docker-build-image.sh cluster
)

# ── NemoClaw: install dependencies ───────────────────────────────────────────
LOCK="${NEMOCLAW_DIR}/node_modules/.package-lock.json"
if [[ ! -f "$LOCK" ]] || [[ "${NEMOCLAW_DIR}/package.json" -nt "$LOCK" ]]; then
    log "Installing NemoClaw dependencies..."
    npm install --prefix "${NEMOCLAW_DIR}"
fi

# ── NemoClaw: onboard ────────────────────────────────────────────────────────
# Ensure secrets are resolved (no-op if already loaded above for LiteLLM)
source "${SCRIPT_DIR}/scripts/resolve-secrets.sh"

export NEMOCLAW_SKIP_VALIDATE=1
export NEMOCLAW_PROVIDER=custom
export NEMOCLAW_ENDPOINT_URL="${NEMOCLAW_ENDPOINT:-http://host.docker.internal:4000/v1}"
export NEMOCLAW_MODEL="${NEMOCLAW_MODEL:-tier-haiku-sensitive}"
export NEMOCLAW_SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
export NEMOCLAW_POLICY_MODE="${NEMOCLAW_POLICY_MODE:-suggested}"
[[ -n "${NEMOCLAW_POLICY_PRESETS:-}" ]] && export NEMOCLAW_POLICY_PRESETS
export COMPATIBLE_API_KEY="${LITELLM_MASTER_KEY}"

run_onboard() {
    node "${NEMOCLAW_DIR}/bin/nemoclaw.js" onboard --non-interactive
}

# Check if already onboarded (sandbox exists and is ready)
existing_sandbox=$(openshell sandbox list 2>/dev/null | awk 'NR>1 && /Ready/ {print $1; exit}' || true)
if [[ -n "$existing_sandbox" ]]; then
    log "Sandbox '${existing_sandbox}' already running — skipping onboard."
else
    log "Running NemoClaw onboard..."
    if ! run_onboard; then
        # Stale gateway state causes first run to fail after cleanup — retry once
        log "Retrying onboard (stale state cleanup)..."
        run_onboard
    fi
fi

log "Stack ready."
