#!/usr/bin/env bash
# nemoclaw-stack lifecycle manager.
#
# Usage:
#   ./stack.sh start [--secrets keychain]   # build + start + onboard
#   ./stack.sh stop  [--clean]              # graceful teardown
#   ./stack.sh ps                           # component status
#   ./stack.sh health                       # test provider connectivity
#
# Environment:
#   STACK_ROOT              Storage root (default: /Volumes/macmini1)
#   NEMOCLAW_MODEL          Model for NemoClaw inference (default: tier-haiku-sensitive)
#   NEMOCLAW_ENDPOINT       LiteLLM endpoint URL (default: https://host.docker.internal:4000/v1)
#   NEMOCLAW_SANDBOX_NAME   Sandbox name (default: my-assistant)
#   NEMOCLAW_POLICY_MODE    Policy preset mode: suggested, custom, skip (default: suggested)
#   NEMOCLAW_POLICY_PRESETS Comma-separated preset names (used with NEMOCLAW_POLICY_MODE=custom)
#   SECRETS_BACKEND         Secrets backend: env, keychain (default: env, or set via --secrets)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Storage root — all state, build artifacts, and tool installs land here ──
export STACK_ROOT="${STACK_ROOT:-/Volumes/macmini1}"
STACK_DATA="${STACK_ROOT}/nemoclaw-stack"

# ── Paths ────────────────────────────────────────────────────────────────────
export COLIMA_HOME="${STACK_DATA}/colima"
export DOCKER_HOST="unix://${COLIMA_HOME}/default/docker.sock"
export XDG_CONFIG_HOME="${STACK_DATA}/config"
export NEMOCLAW_HOME="${STACK_DATA}/state/nemoclaw"
export CARGO_TARGET_DIR="${STACK_DATA}/build/openshell/target"
export MISE_DATA_DIR="${STACK_DATA}/mise"
export OPENSHELL_CLUSTER_IMAGE="openshell/cluster:local"

OPENSHELL_DIR="${SCRIPT_DIR}/openshell"
NEMOCLAW_DIR="${SCRIPT_DIR}/nemoclaw"
LITELLM_VENV="${STACK_DATA}/venv/litellm"
LITELLM_PID="${STACK_DATA}/state/litellm.pid"
LITELLM_LOG="${STACK_DATA}/logs/litellm.log"
LITELLM_CONFIG="${SCRIPT_DIR}/services/litellm/config/litellm_config.built.yaml"
LITELLM_CERT_DIR="${STACK_DATA}/certs"
LITELLM_CERT="${LITELLM_CERT_DIR}/litellm.pem"
LITELLM_KEY="${LITELLM_CERT_DIR}/litellm-key.pem"
BRIDGE_PID="${STACK_DATA}/state/approval-bridge.pid"
MEDIATOR_PID="${STACK_DATA}/state/mediator.pid"
MEDIATOR_LOG="${STACK_DATA}/logs/mediator.log"
MEDIATOR_SOCK="${STACK_DATA}/state/mediator.sock"
MEDIATOR_DB="${STACK_DATA}/state/mediator.db"

log() { echo "▶ $*"; }

# ── CLI parsing ──────────────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift || true

CLEAN=0
if [[ "$COMMAND" != "run" ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --secrets)
                export SECRETS_BACKEND="${2:?--secrets requires a value (env, keychain)}"
                shift 2
                ;;
            --clean)
                CLEAN=1
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                COMMAND=help
                break
                ;;
        esac
    done
fi

# ═════════════════════════════════════════════════════════════════════════════
# COMMANDS
# ═════════════════════════════════════════════════════════════════════════════

cmd_help() {
    cat <<'EOF'
Usage: ./stack.sh <command> [options]

Commands:
  start [--secrets keychain]   Build and start infrastructure services
  create                       Create sandbox and onboard NemoClaw
  stop  [--clean]              Graceful teardown (--clean wipes state dirs)
  ps                           Show component status
  health                       Test LiteLLM and provider connectivity
  env                          Print shell exports (use: eval \$(./stack.sh env))
  run <cmd...>                 Run a command with stack env loaded

Options:
  --secrets <backend>          Secrets backend: env (default), keychain
  --clean                      Wipe state/config/venv dirs on stop
EOF
}

# ── PS ───────────────────────────────────────────────────────────────────────
cmd_ps() {
    local colima_status litellm_status gateway_status sandbox_status bridge_status

    colima_status=$(colima status 2>&1 | grep -o 'running\|not running' || echo 'not running')

    if [[ -f "$LITELLM_PID" ]] && kill -0 "$(cat "$LITELLM_PID")" 2>/dev/null; then
        litellm_status="running (pid $(cat "$LITELLM_PID"))"
    else
        litellm_status="not running"
    fi

    gateway_status=$(docker ps --format '{{.Status}}' --filter name=openshell-cluster-nemoclaw 2>/dev/null || echo 'not running')
    [[ -z "$gateway_status" ]] && gateway_status="not running"

    sandbox_status=$(PATH="${CARGO_TARGET_DIR}/release:${PATH}" openshell sandbox list 2>/dev/null | tail -n +2 || true)
    [[ -z "$sandbox_status" ]] && sandbox_status="none"

    if [[ -f "$BRIDGE_PID" ]] && kill -0 "$(cat "$BRIDGE_PID")" 2>/dev/null; then
        bridge_status="running (pid $(cat "$BRIDGE_PID"))"
    else
        bridge_status="not running"
    fi

    local mediator_status
    if [[ -S "$MEDIATOR_SOCK" ]]; then
        mediator_status="embedded (socket: $MEDIATOR_SOCK)"
    else
        mediator_status="not running"
    fi

    echo "Colima:    ${colima_status}"
    echo "LiteLLM:   ${litellm_status}"
    echo "Gateway:   ${gateway_status}"
    echo "Sandbox:   ${sandbox_status}"
    echo "Bridge:    ${bridge_status}"
    echo "Mediator:  ${mediator_status}"
}

# ── HEALTH ───────────────────────────────────────────────────────────────────
cmd_health() {
    source "${SCRIPT_DIR}/scripts/resolve-secrets.sh"

    local key="${LITELLM_MASTER_KEY:-}"
    if [[ -z "$key" ]]; then
        echo "Error: LITELLM_MASTER_KEY not resolved. Check secrets backend." >&2
        exit 1
    fi

    local base="https://localhost:4000"

    echo "=== LiteLLM proxy ==="
    if curl -sfk --max-time 5 "${base}/health/liveliness" -H "Authorization: Bearer ${key}" >/dev/null 2>&1; then
        echo "  proxy: healthy"
    else
        echo "  proxy: unreachable"
        echo ""
        echo "LiteLLM is not running. Start the stack first: ./stack.sh start"
        exit 1
    fi

    echo ""
    echo "=== Provider keys ==="

    local -a models=(
        "Anthropic:claude-haiku-4-5-20251001"
        "OpenAI:openai/gpt-5.4-nano"
        "Google:gemini/gemini-3.1-flash-lite-preview"
        "xAI:xai/grok-4-fast"
        "Mistral:mistral/mistral-small-2603"
        "OpenRouter:openrouter/deepseek/deepseek-v3.2"
    )

    local all_ok=true
    for entry in "${models[@]}"; do
        local label="${entry%%:*}"
        local model="${entry#*:}"
        local resp content error

        resp=$(curl -sk --max-time 15 "${base}/v1/chat/completions" \
            -H "Authorization: Bearer ${key}" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with only the word pong\"}],\"max_tokens\":5}" 2>&1)

        content=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['choices'][0]['message']['content'])" 2>/dev/null || true)
        error=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); e=r.get('error',{}); print(e.get('message','')[:100] if e else '')" 2>/dev/null || true)

        if [[ -n "$content" ]]; then
            echo "  ✓ ${label}: ok"
        else
            echo "  ✗ ${label}: ${error:-no response / timeout}"
            all_ok=false
        fi
    done

    echo ""
    echo "=== Docker network (host.docker.internal) ==="
    if docker run --rm alpine sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -sfk --max-time 5 https://host.docker.internal:4000/health -H 'Authorization: Bearer ${key}'" >/dev/null 2>&1; then
        echo "  sandbox → litellm: reachable (HTTPS)"
    else
        # 400/401 still means reachable, just not authed for /health
        if docker run --rm alpine sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -sko /dev/null -w '%{http_code}' --max-time 5 https://host.docker.internal:4000/health" 2>/dev/null | grep -qE '^[2-4]'; then
            echo "  sandbox → litellm: reachable (HTTPS)"
        else
            echo "  sandbox → litellm: unreachable"
            all_ok=false
        fi
    fi

    if $all_ok; then
        echo ""
        echo "All checks passed."
    else
        echo ""
        echo "Some checks failed — review above."
        exit 1
    fi
}

# ── START ────────────────────────────────────────────────────────────────────
cmd_start() {
    mkdir -p "$STACK_DATA"

    # ── Colima ──────────────────────────────────────────────────────────────
    rm -f "${COLIMA_HOME}/ssh_config" 2>/dev/null || true
    if ! colima status &>/dev/null; then
        log "Starting Colima..."
        colima start
    fi
    chmod 644 "${COLIMA_HOME}/ssh_config" 2>/dev/null || true

    # ── LiteLLM config ──────────────────────────────────────────────────────
    local built="${LITELLM_CONFIG}"
    if [[ ! -f "$built" ]] || \
       [[ "${SCRIPT_DIR}/services/litellm/config/models.yaml" -nt "$built" ]] || \
       [[ "${SCRIPT_DIR}/services/litellm/config/litellm_config.yaml" -nt "$built" ]] || \
       [[ "${SCRIPT_DIR}/services/litellm/config/trusted_providers.yaml" -nt "$built" ]]; then
        log "Rebuilding LiteLLM config..."
        python3 "${SCRIPT_DIR}/scripts/build_litellm_config.py"
    fi

    # ── TLS certs for LiteLLM ──────────────────────────────────────────────
    if [[ ! -f "$LITELLM_CERT" ]]; then
        log "Generating TLS certificate for LiteLLM..."
        mkdir -p "$LITELLM_CERT_DIR"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$LITELLM_KEY" \
            -out "$LITELLM_CERT" \
            -days 365 -nodes \
            -subj "/CN=litellm" \
            -addext "subjectAltName=DNS:localhost,DNS:host.docker.internal,IP:127.0.0.1" \
            2>/dev/null
        log "TLS cert created (valid 365 days): $LITELLM_CERT"
    fi

    # ── LiteLLM: install + run ──────────────────────────────────────────────
    if [[ ! -d "$LITELLM_VENV" ]]; then
        log "Creating LiteLLM venv..."
        python3 -m venv "$LITELLM_VENV"
        "$LITELLM_VENV/bin/pip" install --quiet 'litellm[proxy]'
    fi

    if [[ -f "$LITELLM_PID" ]] && kill -0 "$(cat "$LITELLM_PID")" 2>/dev/null; then
        log "LiteLLM already running (pid $(cat "$LITELLM_PID"))"
    else
        log "Starting LiteLLM proxy (HTTPS)..."
        mkdir -p "$(dirname "$LITELLM_LOG")" "$(dirname "$LITELLM_PID")"
        source "${SCRIPT_DIR}/scripts/resolve-secrets.sh"
        nohup "$LITELLM_VENV/bin/litellm" \
            --config "$LITELLM_CONFIG" \
            --port 4000 \
            --ssl_keyfile "$LITELLM_KEY" \
            --ssl_certfile "$LITELLM_CERT" \
            > "$LITELLM_LOG" 2>&1 &
        echo $! > "$LITELLM_PID"
        log "LiteLLM started (pid $!, HTTPS on :4000, log: $LITELLM_LOG)"
    fi

    # ── OpenShell: build CLI ────────────────────────────────────────────────
    log "Building OpenShell CLI (incremental)..."
    (
        cd "${OPENSHELL_DIR}"
        mise trust mise.toml &>/dev/null || true
        mise exec -- cargo build --release -p openshell-cli
    )
    export PATH="${CARGO_TARGET_DIR}/release:${PATH}"

    # ── OpenShell: build mediator ──────────────────────────────────────────
    log "Building OpenShell mediator (incremental)..."
    (
        cd "${OPENSHELL_DIR}"
        mise exec -- cargo build --release -p openshell-sandbox
    )

    # ── Mediator env (embedded in sandbox process) ──────────────────────────
    # The mediator now runs inside the sandbox binary. Export env vars so the
    # sandbox process can bootstrap it.
    export MEDIATOR_SOCKET="$MEDIATOR_SOCK"
    export MEDIATOR_DB="sqlite://${MEDIATOR_DB}?mode=rwc"
    if [[ -n "${APPROVAL_BOT_TOKEN:-}" ]]; then
        export APPROVAL_BRIDGE_URL="http://localhost:8090"
    fi
    mkdir -p "$(dirname "$MEDIATOR_SOCK")" "$(dirname "$MEDIATOR_DB")"
    log "Mediator will start embedded in sandbox (socket: $MEDIATOR_SOCK)"

    # ── OpenShell: build cluster image ──────────────────────────────────────
    log "Building OpenShell cluster image (cached)..."
    (
        cd "${OPENSHELL_DIR}"
        IMAGE_TAG=local mise exec -- ./tasks/scripts/docker-build-image.sh cluster
    )

    log "Infrastructure ready. Run './stack.sh create' to create a sandbox."
}

# ── CREATE ──────────────────────────────────────────────────────────────────
cmd_create() {
    export PATH="${CARGO_TARGET_DIR}/release:${PATH}"

    # ── NemoClaw: install dependencies ──────────────────────────────────────
    local lock="${NEMOCLAW_DIR}/node_modules/.package-lock.json"
    if [[ ! -f "$lock" ]] || [[ "${NEMOCLAW_DIR}/package.json" -nt "$lock" ]]; then
        log "Installing NemoClaw dependencies..."
        npm install --prefix "${NEMOCLAW_DIR}"
    fi

    # ── NemoClaw: onboard ───────────────────────────────────────────────────
    source "${SCRIPT_DIR}/scripts/resolve-secrets.sh"

    export NEMOCLAW_SKIP_VALIDATE=1
    export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
    export NEMOCLAW_PROVIDER=custom
    export NEMOCLAW_ENDPOINT_URL="${NEMOCLAW_ENDPOINT:-https://host.docker.internal:4000/v1}"
    export NEMOCLAW_MODEL="${NEMOCLAW_MODEL:-tier-haiku-sensitive}"
    export NEMOCLAW_SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
    export NEMOCLAW_POLICY_MODE="${NEMOCLAW_POLICY_MODE:-suggested}"
    [[ -n "${NEMOCLAW_POLICY_PRESETS:-}" ]] && export NEMOCLAW_POLICY_PRESETS
    export COMPATIBLE_API_KEY="${LITELLM_MASTER_KEY}"

    run_onboard() {
        node "${NEMOCLAW_DIR}/bin/nemoclaw.js" onboard \
            --non-interactive \
            --yes-i-accept-third-party-software
    }

    local existing_sandbox
    existing_sandbox=$(openshell sandbox list 2>/dev/null | awk 'NR>1 && /Ready/ {print $1; exit}' || true)
    if [[ -n "$existing_sandbox" ]]; then
        log "Sandbox '${existing_sandbox}' already running — skipping onboard."
    else
        log "Running NemoClaw onboard..."
        if ! run_onboard; then
            log "Retrying onboard (stale state cleanup)..."
            run_onboard
        fi
    fi

    log "Sandbox ready."
}

# ── STOP ─────────────────────────────────────────────────────────────────────
cmd_stop() {
    export PATH="${CARGO_TARGET_DIR}/release:${PATH}"

    # Fix SSH config (may have been created by another user)
    rm -f "${COLIMA_HOME}/ssh_config" 2>/dev/null || true

    # ── Port forwards ───────────────────────────────────────────────────────
    if command -v openshell &>/dev/null; then
        local forwards
        forwards=$(openshell forward list 2>/dev/null | awk 'NR>1 {print $1, $3}' || true)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local port sandbox
            port=$(echo "$line" | awk '{print $1}')
            sandbox=$(echo "$line" | awk '{print $2}')
            log "Stopping forward ${port} → ${sandbox}..."
            openshell forward stop "$port" "$sandbox" 2>/dev/null || true
        done <<< "$forwards"
    fi

    # ── Sandboxes ───────────────────────────────────────────────────────────
    if command -v openshell &>/dev/null && colima status &>/dev/null; then
        local sandboxes sb
        sandboxes=$(openshell sandbox list 2>/dev/null | awk 'NR>1 {print $1}' || true)
        for sb in $sandboxes; do
            log "Deleting sandbox ${sb}..."
            openshell sandbox delete "$sb" 2>/dev/null || true
        done
    fi

    # ── Gateway ─────────────────────────────────────────────────────────────
    if command -v openshell &>/dev/null && colima status &>/dev/null; then
        if openshell gateway info -g nemoclaw &>/dev/null; then
            log "Destroying gateway..."
            openshell gateway destroy -g nemoclaw 2>/dev/null || true
        fi
    fi

    # ── Mediator (embedded — no separate PID) ─────────────────────────────
    # Mediator is now embedded in the sandbox process; no separate stop needed.
    # Clean up stale socket/pid files if they exist from previous runs.
    rm -f "$MEDIATOR_PID" "$MEDIATOR_SOCK" 2>/dev/null

    # ── Approval Bridge ─────────────────────────────────────────────────────
    _stop_pid_file "$BRIDGE_PID" "approval bridge"

    # ── LiteLLM ─────────────────────────────────────────────────────────────
    _stop_pid_file "$LITELLM_PID" "LiteLLM"

    # ── Orphaned processes ──────────────────────────────────────────────────
    local orphans
    orphans=$(pgrep -f "${STACK_DATA}/(build/openshell|mise/installs)" 2>/dev/null || true)
    if [[ -n "$orphans" ]]; then
        log "Cleaning up orphaned processes..."
        echo "$orphans" | xargs kill -TERM 2>/dev/null || true
        sleep 1
        for pid in $orphans; do
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        done
    fi

    # ── Colima ──────────────────────────────────────────────────────────────
    if colima status &>/dev/null; then
        log "Stopping Colima..."
        colima stop
    fi

    # ── State cleanup ───────────────────────────────────────────────────────
    if [[ "$CLEAN" -eq 1 ]]; then
        log "Wiping state dirs..."
        rm -rf "${STACK_DATA}/state"
        rm -rf "${STACK_DATA}/config"
        rm -rf "${STACK_DATA}/venv"
        rm -rf "${STACK_DATA}/certs"
        log "State wiped."
    fi

    log "Done."
}

cmd_run() {
    export PATH="${CARGO_TARGET_DIR}/release:${PATH}"
    exec "$@"
}

cmd_env() {
    cat <<EOF
export COLIMA_HOME="${COLIMA_HOME}"
export DOCKER_HOST="${DOCKER_HOST}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME}"
export NEMOCLAW_HOME="${NEMOCLAW_HOME}"
EOF
}

# ── Helpers ──────────────────────────────────────────────────────────────────
_stop_pid_file() {
    local pidfile="$1" label="$2"
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            log "Stopping ${label} (pid ${pid})..."
            kill "$pid" 2>/dev/null || true
            for _ in $(seq 1 10); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.5
            done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    fi
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$COMMAND" in
    start)  cmd_start ;;
    create) cmd_create ;;
    stop)   cmd_stop ;;
    ps)     cmd_ps ;;
    health) cmd_health ;;
    env)    cmd_env ;;
    run)    cmd_run "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        cmd_help
        exit 1
        ;;
esac
