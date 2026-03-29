#!/usr/bin/env bash
# Start nemoclaw-stack: build local OpenShell, install NemoClaw deps, boot services.
#
# Usage:
#   ./start.sh              # build + start all services
#   ./start.sh down         # stop everything
#   ./start.sh ps           # show status
#   ./start.sh logs         # tail logs
#
# Override storage root (default: /Volumes/macmini1):
#   STACK_ROOT=/somewhere/else ./start.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Storage root — all state, build artifacts, and tool installs land here ──
export STACK_ROOT="${STACK_ROOT:-/Volumes/macmini1}"

# ── Paths ────────────────────────────────────────────────────────────────────
export COLIMA_HOME="${STACK_ROOT}/config/colima"
export DOCKER_HOST="unix://${COLIMA_HOME}/default/docker.sock"
export XDG_CONFIG_HOME="${STACK_ROOT}/config"       # OpenShell state (kubeconfig, etc.)
export NEMOCLAW_HOME="${STACK_ROOT}/state/nemoclaw"  # NemoClaw state (~/.nemoclaw)
export CARGO_TARGET_DIR="${STACK_ROOT}/build/openshell/target"  # Rust build artifacts
export MISE_DATA_DIR="${STACK_ROOT}/mise"            # mise tool installs
export OPENSHELL_CLUSTER_IMAGE="openshell/cluster:local"

OPENSHELL_DIR="${SCRIPT_DIR}/openshell"
NEMOCLAW_DIR="${SCRIPT_DIR}/nemoclaw"
COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yml"

log() { echo "▶ $*"; }

# ── docker-compose plugin ─────────────────────────────────────────────────────
if ! docker compose version &>/dev/null; then
    prefix="$(brew --prefix 2>/dev/null)/opt/docker-compose/bin/docker-compose"
    if [[ -x "$prefix" ]]; then
        mkdir -p ~/.docker/cli-plugins
        ln -sfn "$prefix" ~/.docker/cli-plugins/docker-compose
    else
        echo "ERROR: docker-compose not found. Run: brew install docker-compose" >&2
        exit 1
    fi
fi

# Short-circuit for non-up commands — no build needed
case "${1:-up}" in
    down|ps|logs)
        $COMPOSE "${@}" 2>/dev/null || true
        exit 0
        ;;
esac

# ── Colima ────────────────────────────────────────────────────────────────────
if ! colima status &>/dev/null; then
    log "Starting Colima..."
    colima start
fi

# ── LiteLLM config ────────────────────────────────────────────────────────────
BUILT="${SCRIPT_DIR}/services/litellm/config/litellm_config.built.yaml"
if [[ ! -f "$BUILT" ]] || \
   [[ "${SCRIPT_DIR}/services/litellm/config/models.yaml" -nt "$BUILT" ]] || \
   [[ "${SCRIPT_DIR}/services/litellm/config/litellm_config.yaml" -nt "$BUILT" ]] || \
   [[ "${SCRIPT_DIR}/services/litellm/config/trusted_providers.yaml" -nt "$BUILT" ]]; then
    log "Rebuilding LiteLLM config..."
    python3 "${SCRIPT_DIR}/scripts/build_litellm_config.py"
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

# ── Compose: bring up services ────────────────────────────────────────────────
log "Starting services..."
$COMPOSE up -d "${@:1}"
