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
#   NEMOCLAW_MODEL          Model for NemoClaw inference (default: tier-sonnet-sensitive)
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

# ── Paths ────────────────────────────────────────────────────────────────────
export COLIMA_HOME="${STACK_DATA}/colima"
export DOCKER_HOST="unix://${COLIMA_HOME}/default/docker.sock"
export XDG_CONFIG_HOME="${STACK_DATA}/config"
export NEMOCLAW_HOME="${STACK_DATA}/state/nemoclaw"
export CARGO_TARGET_DIR="${STACK_DATA}/build/openshell/target"
export MISE_DATA_DIR="${STACK_DATA}/mise"
export OPENSHELL_CLUSTER_IMAGE="openshell/cluster:local"

OPENSHELL_DIR="${SCRIPT_DIR}/openshell"
NEMOCLAW_DIR="${NEMOCLAW_DIR:-${SCRIPT_DIR}/nemoclaw}"
LITELLM_VENV="${STACK_DATA}/venv/litellm"
LITELLM_PID="${STACK_DATA}/state/litellm.pid"
LITELLM_LOG="${STACK_DATA}/logs/litellm.log"
LITELLM_CONFIG="${SCRIPT_DIR}/services/litellm/config/litellm_config.built.yaml"
LITELLM_CERT_DIR="${STACK_DATA}/certs"
LITELLM_CERT="${LITELLM_CERT_DIR}/litellm.pem"
LITELLM_KEY="${LITELLM_CERT_DIR}/litellm-key.pem"
LITELLM_DB_PATH="${STACK_DATA}/state/litellm.db"
LITELLM_NONSENSITIVE_PID="${STACK_DATA}/state/litellm-nonsensitive.pid"
SECRETS_DIR="${STACK_DATA}/secrets"
SENSITIVE_KEY_FILE="${SECRETS_DIR}/litellm_sensitive_key"
NONSENSITIVE_KEY_FILE="${SECRETS_DIR}/litellm_nonsensitive_key"
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
HEALTH_FULL=0
BOOT_PROMPT=""
if [[ "$COMMAND" != "run" && "$COMMAND" != "sandbox" ]]; then
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
            --full)
                HEALTH_FULL=1
                shift
                ;;
            --boot-prompt)
                BOOT_PROMPT="${2:?--boot-prompt requires a file path}"
                shift 2
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

Infrastructure:
  start [--secrets keychain]   Build and start infrastructure (Colima, LiteLLM, cluster image)
  stop  [--clean]              Graceful teardown (--clean wipes state dirs)
  ps                           Show component status
  health [--full]              Test LiteLLM and provider connectivity
  verify-models                Verify all model IDs against live APIs
  env                          Print shell exports (use: eval $(./stack.sh env))
  run <cmd...>                 Run a command with stack env loaded

Sandbox:
  sandbox new [--boot-prompt <file>]   Create sandbox, onboard NemoClaw, configure mediator
  sandbox rebuild                      Rebuild OpenShell binary and hot-deploy (no recreate)
  sandbox ls                           List sandboxes
  sandbox rm [name]                    Delete a sandbox (default: my-assistant)

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
    if [[ -n "$sandbox_status" ]] && openshell sandbox exec -n "$(echo "$sandbox_status" | awk '{print $1}')" -- test -S /sandbox/.mediator/mediator.sock 2>/dev/null; then
        mediator_status="embedded (supervisor PID 1)"
    else
        mediator_status="not running"
    fi

    local nonsensitive_status
    if [[ -f "$LITELLM_NONSENSITIVE_PID" ]] && kill -0 "$(cat "$LITELLM_NONSENSITIVE_PID")" 2>/dev/null; then
        nonsensitive_status="running (pid $(cat "$LITELLM_NONSENSITIVE_PID"), :4001 → :4000)"
    else
        nonsensitive_status="not running"
    fi

    echo "Colima:      ${colima_status}"
    echo "LiteLLM:     ${litellm_status}"
    echo "  sensitive:  :4000 (ZDR providers only)"
    echo "  nonsens.:  ${nonsensitive_status}"
    echo "Gateway:     ${gateway_status}"
    echo "Sandbox:     ${sandbox_status}"
    echo "Bridge:      ${bridge_status}"
    echo "Mediator:    ${mediator_status}"
}

# ── HEALTH ───────────────────────────────────────────────────────────────────
cmd_health() {
    source "${SCRIPT_DIR}/scripts/resolve-secrets.sh"

    local key="${LITELLM_MASTER_KEY:-}"
    if [[ -z "$key" ]]; then
        echo "Error: LITELLM_MASTER_KEY not resolved. Check secrets backend." >&2
        exit 1
    fi

    local base="http://localhost:4000"

    echo "=== LiteLLM proxy ==="
    if curl -sf --max-time 5 "${base}/health/liveliness" -H "Authorization: Bearer ${key}" >/dev/null 2>&1; then
        echo "  :4000 sensitive:    healthy (HTTP)"
    else
        echo "  :4000 sensitive:    unreachable"
        echo ""
        echo "LiteLLM is not running. Start the stack first: ./stack.sh start"
        exit 1
    fi

    if curl -sfk --max-time 5 "https://localhost:4001/health/liveliness" -H "Authorization: Bearer ${key}" >/dev/null 2>&1; then
        echo "  :4001 nonsensitive: healthy (HTTPS → HTTP :4000)"
    else
        echo "  :4001 nonsensitive: not running (socat redirect)"
    fi

    echo ""
    echo "=== Direct provider keys ==="

    local -a direct_models=(
        "Anthropic:claude-haiku-4-5-20251001"
        "OpenAI:openai/gpt-5.4-nano"
        "Google:gemini/gemini-3.1-flash-lite-preview"
        "xAI:xai/grok-4-fast"
        "Mistral:mistral/mistral-small-2603"
        "OpenRouter:openrouter/deepseek/deepseek-v3.2"
    )

    local -a models=("${direct_models[@]}")

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
    echo "=== Model tier routing ==="
    echo "  (tests the full LiteLLM routing chain including fallbacks)"

    local -a tiers=(
        "tier-opus-sensitive"
        "tier-sonnet-sensitive"
        "tier-haiku-sensitive"
        "tier-opus-nonsensitive"
        "tier-sonnet-nonsensitive"
        "tier-haiku-nonsensitive"
    )

    for tier in "${tiers[@]}"; do
        local resp content error
        resp=$(curl -sk --max-time 30 "${base}/v1/chat/completions" \
            -H "Authorization: Bearer ${key}" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"${tier}\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with only the word pong\"}],\"max_tokens\":5}" 2>&1)

        content=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['choices'][0]['message']['content'])" 2>/dev/null || true)
        error=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); e=r.get('error',{}); print(e.get('message','')[:100] if e else '')" 2>/dev/null || true)
        # Extract which model actually served the request
        local served_model
        served_model=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model','?'))" 2>/dev/null || echo "?")

        if [[ -n "$content" ]]; then
            echo "  ✓ ${tier}: ok (served by ${served_model})"
        else
            echo "  ✗ ${tier}: ${error:-no response / timeout}"
            all_ok=false
        fi
    done

    # ── Full OpenRouter provider test (--full only) ────────────────────────
    if [[ "$HEALTH_FULL" -eq 1 ]]; then
        echo ""
        echo "=== OpenRouter providers (--full) ==="
        echo "  Testing each whitelisted provider individually..."
        echo "  (this may take several minutes)"

        local providers_file="${SCRIPT_DIR}/services/litellm/config/trusted_providers.yaml"
        if [[ ! -f "$providers_file" ]]; then
            echo "  ✗ trusted_providers.yaml not found"
        else
            local or_key="${OPENROUTER_API_KEY:-}"
            if [[ -z "$or_key" ]]; then
                echo "  ✗ OPENROUTER_API_KEY not set — skipping"
            else
                # Parse provider names from YAML list
                local providers
                providers=$(python3 -c "
import yaml, sys
with open('$providers_file') as f:
    data = yaml.safe_load(f)
if isinstance(data, list):
    for p in data:
        print(p)
elif isinstance(data, dict):
    for p in data.get('providers', data.get('trusted_providers', [])):
        print(p)
" 2>/dev/null)

                local or_ok=0 or_fail=0 or_total=0
                while IFS= read -r provider; do
                    [[ -z "$provider" ]] && continue
                    ((or_total++))

                    # Use OpenRouter's provider routing to force this specific provider
                    # with a cheap model (meta-llama/llama-3.3-8b-instruct:free or similar)
                    local resp content
                    resp=$(curl -sk --max-time 20 "https://openrouter.ai/api/v1/chat/completions" \
                        -H "Authorization: Bearer ${or_key}" \
                        -H "Content-Type: application/json" \
                        -d "{
                            \"model\": \"meta-llama/llama-3.3-8b-instruct:free\",
                            \"messages\": [{\"role\": \"user\", \"content\": \"respond with only the word pong\"}],
                            \"max_tokens\": 5,
                            \"provider\": {
                                \"order\": [\"${provider}\"],
                                \"allow_fallbacks\": false
                            }
                        }" 2>&1)

                    content=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['choices'][0]['message']['content'])" 2>/dev/null || true)

                    if [[ -n "$content" ]]; then
                        echo "  ✓ ${provider}"
                        ((or_ok++))
                    else
                        local or_error
                        or_error=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); e=r.get('error',{}); print(e.get('message','')[:80] if e else '')" 2>/dev/null || true)
                        echo "  ✗ ${provider}: ${or_error:-no response}"
                        ((or_fail++))
                    fi
                done <<< "$providers"

                echo ""
                echo "  OpenRouter: ${or_ok}/${or_total} providers reachable, ${or_fail} failed"
                if [[ $or_fail -gt 0 ]]; then
                    echo "  (failed providers will be skipped by LiteLLM routing — not fatal)"
                fi
            fi
        fi
    fi

    echo ""
    echo "=== Docker network (host.docker.internal) ==="

    # Sensitive endpoint (:4000) — plain HTTP, see comment in cmd_start.
    if docker run --rm alpine sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -sf --max-time 5 http://host.docker.internal:4000/health -H 'Authorization: Bearer ${key}'" >/dev/null 2>&1; then
        echo "  :4000 sensitive:    reachable (HTTP)"
    else
        if docker run --rm alpine sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -so /dev/null -w '%{http_code}' --max-time 5 http://host.docker.internal:4000/health" 2>/dev/null | grep -qE '^[2-4]'; then
            echo "  :4000 sensitive:    reachable (HTTP)"
        else
            echo "  :4000 sensitive:    unreachable"
            all_ok=false
        fi
    fi

    # Nonsensitive redirect (:4001) — HTTPS terminator forwarding to HTTP :4000.
    if docker run --rm alpine sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -sfk --max-time 5 https://host.docker.internal:4001/health -H 'Authorization: Bearer ${key}'" >/dev/null 2>&1; then
        echo "  :4001 nonsensitive: reachable (HTTPS → HTTP :4000)"
    else
        if docker run --rm alpine sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -sko /dev/null -w '%{http_code}' --max-time 5 https://host.docker.internal:4001/health" 2>/dev/null | grep -qE '^[2-4]'; then
            echo "  :4001 nonsensitive: reachable (HTTPS → HTTP :4000)"
        else
            echo "  :4001 nonsensitive: unreachable (socat may not be running)"
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
        "$LITELLM_VENV/bin/pip" install --quiet 'litellm[proxy]' prisma
        # Generate Prisma client for database mode (SQLite key management).
        local schema_path
        schema_path=$("$LITELLM_VENV/bin/python3" -c \
            "import litellm,os; print(os.path.join(os.path.dirname(litellm.__file__),'proxy','schema.prisma'))")
        PATH="$LITELLM_VENV/bin:$PATH" prisma generate --schema="$schema_path" 2>/dev/null || \
            log "Warning: prisma generate failed — key scoping may not work"
    fi

    if [[ -f "$LITELLM_PID" ]] && kill -0 "$(cat "$LITELLM_PID")" 2>/dev/null; then
        log "LiteLLM already running (pid $(cat "$LITELLM_PID"))"
    else
        log "Starting LiteLLM proxy (HTTP on :4000)..."
        mkdir -p "$(dirname "$LITELLM_LOG")" "$(dirname "$LITELLM_PID")" "$SECRETS_DIR"
        source "${SCRIPT_DIR}/scripts/resolve-secrets.sh"
        # DATABASE_URL for key scoping requires Prisma engine — disabled for now.
        # export DATABASE_URL="sqlite:///${LITELLM_DB_PATH}"
        # NOTE: 4000 is plain HTTP because openshell-router uses rustls without
        # native-roots and won't trust our self-signed cert. Hop is loopback
        # only (Colima gvproxy bridge), never leaves the host. The 4001 socat
        # below still terminates HTTPS for the nonsensitive tier.
        nohup "$LITELLM_VENV/bin/litellm" \
            --config "$LITELLM_CONFIG" \
            --port 4000 \
            > "$LITELLM_LOG" 2>&1 &
        echo $! > "$LITELLM_PID"
        log "LiteLLM started (pid $!, HTTP on :4000, log: $LITELLM_LOG)"
    fi

    # ── LiteLLM: wait for readiness ──────────────────────────────────────
    _wait_for_litellm || log "Warning: LiteLLM may not be ready yet"

    # NOTE: Per-key model scoping (sensitive vs nonsensitive) requires LiteLLM
    # database mode with Prisma, which needs a running Prisma engine.
    # For now, all callers use LITELLM_MASTER_KEY. Model tier enforcement
    # relies on the agent's system prompt and URL-based trust classification.
    # TODO: Enable key scoping when Prisma SQLite support is viable.

    # ── LiteLLM: nonsensitive redirect on port 4001 ───────────────────────
    # Port 4001 is a TLS pass-through to the same LiteLLM on 4000.
    # Children with the unrestricted key (mounted file) hit 4001.
    # The trust spec classifies 4000 as trusted (sensitive) and 4001 as
    # untrusted for PII (nonsensitive providers). Same LiteLLM instance,
    # different trust boundary for taint analysis.
    if [[ -f "$LITELLM_NONSENSITIVE_PID" ]] && kill -0 "$(cat "$LITELLM_NONSENSITIVE_PID")" 2>/dev/null; then
        log "Nonsensitive redirect already running (pid $(cat "$LITELLM_NONSENSITIVE_PID"))"
    else
        if command -v socat &>/dev/null; then
            log "Starting nonsensitive inference redirect (:4001 → :4000)..."
            # Terminate TLS at 4001 (still needed for taint-classification by URL),
            # forward as plain TCP to 4000 (LiteLLM is HTTP since openshell-router
            # rustls won't trust the self-signed cert).
            nohup socat \
                OPENSSL-LISTEN:4001,cert="$LITELLM_CERT",key="$LITELLM_KEY",verify=0,fork,reuseaddr \
                TCP:localhost:4000 \
                > /dev/null 2>&1 &
            echo $! > "$LITELLM_NONSENSITIVE_PID"
            log "Nonsensitive redirect started (pid $!, HTTPS :4001 → HTTP :4000)"
        else
            log "Warning: socat not installed — nonsensitive redirect on :4001 unavailable."
            log "  Children will share the sensitive endpoint on :4000."
        fi
    fi

    # ── LiteLLM: verify all model IDs ────────────────────────────────────
    log "Verifying model IDs against live APIs..."
    if ! "${SCRIPT_DIR}/scripts/verify-models.sh"; then
        log "Warning: some model IDs failed verification (non-fatal, continuing)"
    fi

    # ── OpenShell: build CLI ────────────────────────────────────────────────
    log "Building OpenShell CLI (incremental)..."
    (
        cd "${OPENSHELL_DIR}"
        mise trust mise.toml &>/dev/null || true
        mise exec -- cargo build --release -p openshell-cli
    )
    export PATH="${CARGO_TARGET_DIR}/release:${PATH}"

    # ── OpenShell: build mediator + CLI + daemon ──────────────────────────
    log "Building OpenShell mediator (incremental)..."
    (
        cd "${OPENSHELL_DIR}"
        mise exec -- cargo build --release -p openshell-sandbox
    )
    # The mediator runs embedded inside the OpenShell sandbox supervisor
    # (PID 1). No standalone binary needed — env vars in Dockerfile.sandbox
    # configure it (INIT_INFERENCE_ENDPOINT, APPROVAL_BRIDGE_URL).

    # ── Approval bridge ─────────────────────────────────────────────────────
    # Started here so it's already listening when the sandbox boots and the
    # in-sandbox mediator daemon tries to POST policy proposals to it.
    # The mediator daemon (running inside the sandbox container) reaches
    # this bridge via host.docker.internal:8090. Without the bridge running,
    # the new fail-closed default in policy_propose denies every proposal.
    if [[ -n "${APPROVAL_BOT_TOKEN:-}" ]]; then
        if [[ -f "$BRIDGE_PID" ]] && kill -0 "$(cat "$BRIDGE_PID")" 2>/dev/null; then
            log "Approval bridge already running (pid $(cat "$BRIDGE_PID"))"
        else
            log "Starting approval bridge on :8090..."
            "${SCRIPT_DIR}/services/approval-bridge/start.sh" --bg \
                && log "Approval bridge started" \
                || log "Warning: approval bridge start failed"
        fi
    else
        log "APPROVAL_BOT_TOKEN not set — skipping approval bridge"
        log "  policy_propose will fail-CLOSED until the bridge is configured"
    fi

    # ── OpenShell: build cluster image ──────────────────────────────────────
    # Use a hash of the sandbox crate source to bust the Docker cargo cache
    # when code changes. Without this, BuildKit reuses stale compilation
    # artifacts and the binary in the image doesn't include our changes.
    local src_hash
    src_hash=$(find "${OPENSHELL_DIR}/crates/openshell-sandbox/src" -name '*.rs' -exec md5 -q {} + 2>/dev/null | md5 -q 2>/dev/null || echo "default")
    log "Building OpenShell cluster image (source hash: ${src_hash:0:8})..."
    (
        cd "${OPENSHELL_DIR}"
        CARGO_TARGET_CACHE_SCOPE="${src_hash}" IMAGE_TAG=local \
            mise exec -- ./tasks/scripts/docker-build-image.sh cluster
    )

    # ── Layer NemoClaw plugin (with mediator tools) on top ────────────────
    # The base cluster image has OpenClaw but not the NemoClaw plugin.
    # Build a thin layer that installs the pre-built plugin so mediator
    # syscalls (policy_propose, fork_with_policy, ipc_send, etc.) are
    # available as native agent tools.
    local nemoclaw_plugin_src
    nemoclaw_plugin_src="$(cd "${NEMOCLAW_DIR}/nemoclaw" 2>/dev/null && pwd)"
    if [[ -f "${SCRIPT_DIR}/Dockerfile.sandbox" && -d "${nemoclaw_plugin_src}/dist" ]]; then
        log "Building sandbox image with NemoClaw plugin..."
        # Stage the built plugin into .build/ for the Docker build context.
        local staging="${SCRIPT_DIR}/.build/nemoclaw-plugin"
        rm -rf "$staging"
        mkdir -p "$staging/dist"
        cp "${nemoclaw_plugin_src}/dist/index.js" "$staging/dist/"
        cp "${nemoclaw_plugin_src}/dist/mediator-tools.js" "$staging/dist/" 2>/dev/null || true
        cp "${nemoclaw_plugin_src}/openclaw.plugin.json" "$staging/"
        cp "${nemoclaw_plugin_src}/package.json" "$staging/"
        if docker build \
            -f "${SCRIPT_DIR}/Dockerfile.sandbox" \
            -t openshell/cluster:local \
            "${SCRIPT_DIR}" >/dev/null 2>&1; then
            log "Sandbox image built with NemoClaw plugin (mediator tools included)"
        else
            log "Warning: sandbox image build failed — mediator tools will not be native agent tools"
        fi
        rm -rf "${SCRIPT_DIR}/.build"
    fi

    log "Infrastructure ready. Run './stack.sh sandbox new' to create a sandbox."
}

# ── SANDBOX ────────────────────────────────────────────────────────────────
cmd_sandbox() {
    local sub="${1:-help}"; shift 2>/dev/null || true
    # Parse sandbox-specific flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --boot-prompt) BOOT_PROMPT="${2:?--boot-prompt requires a file path}"; shift 2 ;;
            *) break ;;
        esac
    done
    case "$sub" in
        new)    cmd_sandbox_new "$@" ;;
        rebuild|deploy) cmd_deploy "$@" ;;
        ls|list) cmd_sandbox_ls ;;
        rm|delete) cmd_sandbox_rm "$@" ;;
        *)
            echo "Usage: ./stack.sh sandbox {new|deploy|ls|rm}" >&2
            exit 1 ;;
    esac
}

cmd_sandbox_ls() {
    export PATH="${CARGO_TARGET_DIR}/release:${PATH}"
    openshell sandbox list 2>/dev/null
}

cmd_sandbox_rm() {
    export PATH="${CARGO_TARGET_DIR}/release:${PATH}"
    local name="${1:-${NEMOCLAW_SANDBOX_NAME:-my-assistant}}"
    log "Deleting sandbox ${name}..."
    openshell sandbox delete "$name" 2>&1
}

# ── SANDBOX NEW ────────────────────────────────────────────────────────────
cmd_sandbox_new() {
    export PATH="${CARGO_TARGET_DIR}/release:${PATH}"

    # ── Source root .env for Telegram/Discord/Slack tokens ──────────────────
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        set -a; source "${SCRIPT_DIR}/.env"; set +a
    fi

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
    export NEMOCLAW_ENDPOINT_URL="${NEMOCLAW_ENDPOINT:-http://host.docker.internal:4000/v1}"
    # Default to sonnet tier — haiku is too small for the multi-step tool
    # chains the mediator skill requires (recognize gap → read SKILL.md →
    # exec mediator-cli → parse JSON → follow up). Haiku confabulates the
    # call instead of executing it.
    export NEMOCLAW_MODEL="${NEMOCLAW_MODEL:-tier-sonnet-sensitive}"
    export NEMOCLAW_SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
    export NEMOCLAW_POLICY_MODE="${NEMOCLAW_POLICY_MODE:-suggested}"
    [[ -n "${NEMOCLAW_POLICY_PRESETS:-}" ]] && export NEMOCLAW_POLICY_PRESETS
    export COMPATIBLE_API_KEY="${LITELLM_MASTER_KEY}"

    # Ensure Telegram/Discord/Slack tokens (and DM allowlists) are exported
    # for the onboard build. onboard.js reads these from process.env to bake
    # the messaging channel and allowed_ids into the sandbox image.
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && export TELEGRAM_BOT_TOKEN
    [[ -n "${TELEGRAM_ALLOWED_IDS:-}" ]] && export TELEGRAM_ALLOWED_IDS
    [[ -n "${DISCORD_BOT_TOKEN:-}" ]] && export DISCORD_BOT_TOKEN
    [[ -n "${DISCORD_ALLOWED_IDS:-}" ]] && export DISCORD_ALLOWED_IDS
    [[ -n "${SLACK_BOT_TOKEN:-}" ]] && export SLACK_BOT_TOKEN
    [[ -n "${SLACK_ALLOWED_IDS:-}" ]] && export SLACK_ALLOWED_IDS

    run_onboard() {
        node "${NEMOCLAW_DIR}/bin/nemoclaw.js" onboard \
            --non-interactive \
            --yes-i-accept-third-party-software
    }

    local existing_sandbox
    existing_sandbox=$(openshell sandbox list 2>/dev/null | awk 'NR>1 && /Ready/ {print $1; exit}' || true)
    if [[ -n "$existing_sandbox" && "${NEMOCLAW_RECREATE_SANDBOX:-0}" != "1" ]]; then
        log "Sandbox '${existing_sandbox}' already running — skipping onboard."
        log "  (set NEMOCLAW_RECREATE_SANDBOX=1 to force a rebuild, e.g. after editing .env)"
    else
        if [[ -n "$existing_sandbox" ]]; then
            log "NEMOCLAW_RECREATE_SANDBOX=1 — onboard will recreate sandbox '${existing_sandbox}'."
        fi
        log "Running NemoClaw onboard..."
        if ! run_onboard; then
            log "Retrying onboard (stale state cleanup)..."
            run_onboard
        fi
    fi

    # The mediator daemon runs embedded in the OpenShell supervisor (PID 1).
    # No standalone binaries to upload. Only the agent-bootstrap script and
    # skill files need to go into the sandbox.
    local sandbox_name="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"

    # ── Upload agent-bootstrap script ─────────────────────────────���─────
    # Sets up an OpenClaw agent workspace and runs --local under the
    # child's UID. Used as the launch command in fork_with_policy.
    local bootstrap_src="${SCRIPT_DIR}/scripts/sandbox-tools/agent-bootstrap.sh"
    if [[ -f "$bootstrap_src" ]]; then
        openshell sandbox upload "$sandbox_name" "$bootstrap_src" "/sandbox/" \
            && openshell sandbox exec -n "$sandbox_name" -- chmod +x /sandbox/agent-bootstrap.sh \
            && log "agent-bootstrap.sh uploaded to /sandbox/agent-bootstrap.sh" \
            || log "Warning: agent-bootstrap.sh upload failed"
    fi

    # ── Mediator post-create setup ───────────────────────────────────────
    # The embedded mediator reads config.json at runtime for settings that
    # can't be injected via pod env vars (PVC is empty at boot time).
    # Also writes the LiteLLM API key and Brave search key.
    _setup_mediator "$sandbox_name"

    # ── Install mediator skill ─────────────────────────────────────────────
    # The mediator skill teaches OpenClaw when/how to use the mediator
    # syscall API. Without it, the agent never reaches for fork_with_policy
    # and just refuses requests it could otherwise route through a child.
    # Lives in the user-managed skills dir (CONFIG_DIR/skills) and is
    # discovered by OpenClaw's loadSkillsFromDir at session start.
    local skill_src="${SCRIPT_DIR}/skills/mediator/SKILL.md"
    if [[ -f "$skill_src" ]]; then
        log "Installing mediator skill into sandbox..."
        if openshell sandbox upload "$sandbox_name" "$skill_src" "/tmp/" >/dev/null 2>&1 \
            && openshell sandbox exec -n "$sandbox_name" -- sh -c \
                'mkdir -p /sandbox/.openclaw-data/skills/mediator && mv /tmp/SKILL.md /sandbox/.openclaw-data/skills/mediator/SKILL.md'; then
            log "Mediator skill installed"
        else
            log "Warning: mediator skill install failed"
        fi
    fi

    # ── Upload agent syscall guide ─────────────────────────────────────────
    # NOTE: `openshell sandbox upload` always treats DEST as a parent directory
    # and uses the source basename for the file. To land at MEDIATOR.md we have
    # to stage a temp copy with the right name and then move it into place.
    local guide="${SCRIPT_DIR}/docs/agent-syscall-guide.md"
    if [[ -f "$guide" ]]; then
        log "Uploading agent syscall guide to sandbox..."
        local guide_tmp
        guide_tmp="$(mktemp -d)/MEDIATOR.md"
        cp "$guide" "$guide_tmp"
        if openshell sandbox upload "$sandbox_name" "$guide_tmp" "/tmp/" \
            && openshell sandbox exec -n "$sandbox_name" -- \
                mv /tmp/MEDIATOR.md /sandbox/.openclaw/workspace/MEDIATOR.md; then
            log "Syscall guide uploaded as MEDIATOR.md"
        else
            log "Warning: guide upload failed"
        fi
        rm -rf "$(dirname "$guide_tmp")"
    fi

    # ── Inject boot prompt (AGENTS.md) into sandbox workspace ────────────
    # Source: --boot-prompt flag, NEMOCLAW_BOOT_PROMPT env var, or default.
    # Default points at the mediator-aware boot prompt so the agent knows
    # about the syscall API at session start.
    local boot_prompt="${BOOT_PROMPT:-${NEMOCLAW_BOOT_PROMPT:-${SCRIPT_DIR}/tests/boot-prompts/default-mediator.md}}"
    if [[ -n "$boot_prompt" ]]; then
        if [[ ! -f "$boot_prompt" ]]; then
            echo "Error: boot prompt file not found: $boot_prompt" >&2
            exit 1
        fi
        log "Injecting boot prompt into sandbox workspace..."
        # Upload AGENTS.md to the workspace inside the sandbox via the same
        # tmp-rename dance MEDIATOR.md needs.
        local agents_tmp
        agents_tmp="$(mktemp -d)/AGENTS.md"
        cp "$boot_prompt" "$agents_tmp"
        if openshell sandbox upload "$sandbox_name" "$agents_tmp" "/tmp/" \
            && openshell sandbox exec -n "$sandbox_name" -- \
                mv /tmp/AGENTS.md /sandbox/.openclaw/workspace/AGENTS.md; then
            log "Boot prompt injected: $boot_prompt → AGENTS.md"
        else
            log "Warning: boot prompt injection failed"
        fi
        rm -rf "$(dirname "$agents_tmp")"
    fi

    # ── Activate mediator-tools plugin (post-gateway-start) ─────────────
    # The plugin files are baked into the image at
    # /sandbox/.openclaw-data/extensions/mediator-tools/ but dormant until
    # plugins.load.paths references them. We patch the config AFTER the
    # gateway has completed its startup migration — patching before startup
    # causes a delayed crash. The gateway hot-reloads config changes.
    if openshell sandbox exec -n "$sandbox_name" -- \
            test -f /sandbox/.openclaw-data/extensions/mediator-tools/openclaw.plugin.json 2>/dev/null; then
        log "Activating mediator-tools plugin..."
        docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox_name" -- \
            python3 -c "
import json
cfg = json.load(open('/sandbox/.openclaw/openclaw.json'))
cfg.setdefault('plugins', {})['load'] = {'paths': ['/sandbox/.openclaw-data/extensions/mediator-tools']}
json.dump(cfg, open('/sandbox/.openclaw/openclaw.json', 'w'), indent=2)
print('ok')
" >/dev/null 2>&1 \
          && log "Mediator tools plugin activated (gateway will hot-reload)" \
          || log "Warning: mediator tools plugin activation failed"
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
    # Embedded mediator stops with the sandbox — no host-side cleanup needed.

    # ── Approval Bridge ─────────────────────────────────────────────────────
    _stop_pid_file "$BRIDGE_PID" "approval bridge"

    # ── LiteLLM + nonsensitive redirect ────────────────────────────────────
    _stop_pid_file "$LITELLM_NONSENSITIVE_PID" "nonsensitive redirect"
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
        rm -rf "${STACK_DATA}/secrets"
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

# ── DEPLOY ──────────────────────────────────────────────────────────────────
# Rebuild the OpenShell binary and hot-deploy it into the running cluster
# without recreating the sandbox. Use after making code changes to OpenShell.
cmd_deploy() {
    export PATH="${CARGO_TARGET_DIR}/release:${PATH}"

    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        set -a; source "${SCRIPT_DIR}/.env"; set +a
    fi
    source "${SCRIPT_DIR}/scripts/resolve-secrets.sh" 2>/dev/null || true

    local sandbox_name="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"

    # 1. Rebuild cluster image with cache-busted sandbox binary
    local src_hash
    src_hash=$(find "${OPENSHELL_DIR}/crates/openshell-sandbox/src" -name '*.rs' -exec md5 -q {} + 2>/dev/null | md5 -q 2>/dev/null || echo "$(date +%s)")
    log "Building OpenShell cluster image (source hash: ${src_hash:0:8})..."
    (
        cd "${OPENSHELL_DIR}"
        CARGO_TARGET_CACHE_SCOPE="${src_hash}" IMAGE_TAG=local \
            mise exec -- ./tasks/scripts/docker-build-image.sh cluster
    )

    # 2. Layer NemoClaw plugin
    local nemoclaw_plugin_src
    nemoclaw_plugin_src="$(cd "${NEMOCLAW_DIR}/nemoclaw" 2>/dev/null && pwd)"
    if [[ -f "${SCRIPT_DIR}/Dockerfile.sandbox" && -d "${nemoclaw_plugin_src}/dist" ]]; then
        local staging="${SCRIPT_DIR}/.build/nemoclaw-plugin"
        rm -rf "$staging"; mkdir -p "$staging/dist"
        cp "${nemoclaw_plugin_src}/dist/index.js" "$staging/dist/"
        cp "${nemoclaw_plugin_src}/dist/mediator-tools.js" "$staging/dist/" 2>/dev/null || true
        cp "${nemoclaw_plugin_src}/openclaw.plugin.json" "$staging/"
        cp "${nemoclaw_plugin_src}/package.json" "$staging/"
        docker build -f "${SCRIPT_DIR}/Dockerfile.sandbox" -t openshell/cluster:local "${SCRIPT_DIR}" >/dev/null 2>&1
        rm -rf "${SCRIPT_DIR}/.build"
    fi

    # 3. Extract binary and copy to cluster HostPath
    log "Deploying new binary to cluster..."
    local tmp_bin="/tmp/openshell-sandbox-deploy-$$"
    docker run --rm --entrypoint="" openshell/cluster:local \
        cat /opt/openshell/bin/openshell-sandbox > "$tmp_bin" 2>/dev/null
    docker cp "$tmp_bin" openshell-cluster-nemoclaw:/opt/openshell/bin/openshell-sandbox
    docker exec openshell-cluster-nemoclaw chmod +x /opt/openshell/bin/openshell-sandbox
    rm -f "$tmp_bin"
    log "Binary deployed ($(docker exec openshell-cluster-nemoclaw wc -c < /opt/openshell/bin/openshell-sandbox 2>/dev/null) bytes)"

    # 4. Clean stale mediator DB (schema may have changed) and restart pod
    log "Restarting sandbox pod..."
    docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox_name" -- \
        sh -c 'rm -f /sandbox/.mediator/mediator.db /sandbox/.mediator/mediator.db-* /sandbox/.mediator/mediator.sock /sandbox/.mediator/mediator.sock.token' 2>/dev/null
    docker exec openshell-cluster-nemoclaw kubectl delete pod "$sandbox_name" -n openshell 2>/dev/null

    # 5. Wait for pod to come back
    log "Waiting for pod to restart..."
    local waited=0
    while [[ $waited -lt 90 ]]; do
        if docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox_name" -- \
                test -S /sandbox/.mediator/mediator.sock 2>/dev/null; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    if [[ $waited -ge 90 ]]; then
        log "Warning: pod did not become ready within 90s"
        return 1
    fi

    # 6. Re-apply mediator config + keys
    _setup_mediator "$sandbox_name"

    # 7. Upload bootstrap + skill
    local bootstrap_src="${SCRIPT_DIR}/scripts/sandbox-tools/agent-bootstrap.sh"
    if [[ -f "$bootstrap_src" ]]; then
        openshell sandbox upload "$sandbox_name" "$bootstrap_src" "/sandbox/" >/dev/null 2>&1 \
            && openshell sandbox exec -n "$sandbox_name" -- chmod +x /sandbox/agent-bootstrap.sh 2>/dev/null
        log "agent-bootstrap.sh deployed"
    fi
    local skill_src="${SCRIPT_DIR}/skills/mediator/SKILL.md"
    if [[ -f "$skill_src" ]]; then
        openshell sandbox upload "$sandbox_name" "$skill_src" "/tmp/" >/dev/null 2>&1 \
            && openshell sandbox exec -n "$sandbox_name" -- sh -c \
                'mkdir -p /sandbox/.openclaw-data/skills/mediator && mv /tmp/SKILL.md /sandbox/.openclaw-data/skills/mediator/SKILL.md' 2>/dev/null
        log "Mediator skill deployed"
    fi

    # 8. Restart the OpenClaw gateway (killed by pod restart).
    # The gateway is normally started by NemoClaw's onboard, which only runs
    # during initial sandbox creation. After a pod restart, we have to
    # re-launch it manually with the right environment.
    log "Restarting OpenClaw gateway..."
    docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox_name" -- \
        sh -c 'export HOME=/sandbox; export NODE_USE_ENV_PROXY=1; nohup openclaw gateway > /tmp/gateway-rebuild.log 2>&1 &' 2>/dev/null
    sleep 8
    if docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox_name" -- \
            pidof openclaw-gateway >/dev/null 2>&1; then
        log "Gateway restarted"
    else
        log "Warning: gateway did not restart. Check /tmp/gateway-rebuild.log in the sandbox."
        log "  You may need to run './stack.sh sandbox rm && ./stack.sh sandbox new' instead."
    fi

    log "Rebuild complete."
}

# ── Mediator post-create setup helper ────────────────────────────────────────
_setup_mediator() {
    local sandbox_name="$1"

    # Source secrets
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        set -a; source "${SCRIPT_DIR}/.env"; set +a
    fi
    source "${SCRIPT_DIR}/scripts/resolve-secrets.sh" 2>/dev/null || true

    local bridge_url=""
    [[ -n "${APPROVAL_BOT_TOKEN:-}" ]] && bridge_url="http://host.docker.internal:8090"

    # Write mediator config.json via kubectl exec (avoids openshell sandbox exec quoting issues)
    docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox_name" -- sh -c "
mkdir -p /sandbox/.mediator
cat > /sandbox/.mediator/config.json << 'MCONF'
{\"APPROVAL_BRIDGE_URL\":\"${bridge_url}\",\"INIT_INFERENCE_ENDPOINT\":\"http://host.docker.internal:4000/*\"}
MCONF
" >/dev/null 2>&1 \
      && log "Mediator config written" \
      || log "Warning: failed to write mediator config"

    # Write LiteLLM API key (for child agents calling LiteLLM directly)
    if [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then
        docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox_name" -- \
            sh -c "echo '${LITELLM_MASTER_KEY}' > /sandbox/.mediator/litellm.key && chmod 644 /sandbox/.mediator/litellm.key" >/dev/null 2>&1 \
          && log "LiteLLM key written" \
          || log "Warning: failed to write LiteLLM key"
    fi

    # Inject Brave Search API key into OpenClaw config (gateway hot-reloads)
    if [[ -n "${BRAVE_API_KEY:-}" ]]; then
        docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox_name" -- \
            python3 -c "
import json
cfg = json.load(open('/sandbox/.openclaw/openclaw.json'))
cfg.setdefault('tools', {}).setdefault('web', {})['search'] = {
    'enabled': True, 'provider': 'brave',
    'apiKey': '${BRAVE_API_KEY}'
}
cfg['tools']['web']['fetch'] = {'enabled': True}
json.dump(cfg, open('/sandbox/.openclaw/openclaw.json', 'w'), indent=2)
" >/dev/null 2>&1 \
          && log "Brave Search key injected" \
          || log "Warning: failed to inject Brave key"
    fi

    # Inject MEDIATOR_SOCKET/MEDIATOR_TOKEN into bashrc
    docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox_name" -- \
        sh -c 'token=$(cat /sandbox/.mediator/mediator.sock.token 2>/dev/null || echo ""); for rc in /sandbox/.bashrc /sandbox/.profile; do if ! grep -qF "MEDIATOR_SOCKET" "$rc" 2>/dev/null; then printf "\n# mediator (embedded in supervisor)\nexport MEDIATOR_SOCKET=/sandbox/.mediator/mediator.sock\nexport MEDIATOR_TOKEN=%s\n" "$token" >> "$rc"; fi; done' >/dev/null 2>&1 \
      && log "Mediator env vars injected" \
      || log "Warning: failed to inject mediator env vars"

    # Start approval bridge if not running
    if [[ -n "${APPROVAL_BOT_TOKEN:-}" ]]; then
        if [[ -f "$BRIDGE_PID" ]] && kill -0 "$(cat "$BRIDGE_PID")" 2>/dev/null; then
            log "Approval bridge already running"
        else
            log "Starting approval bridge..."
            (
                cd "${SCRIPT_DIR}/services/approval-bridge"
                TELEGRAM_BOT_TOKEN="${APPROVAL_BOT_TOKEN}" \
                APPROVAL_CHAT_ID="${TELEGRAM_ALLOWED_IDS}" \
                    nohup python3 main.py > "${STACK_DATA}/logs/bridge.log" 2>&1 &
                echo $! > "$BRIDGE_PID"
            )
            sleep 3
            if curl -s http://localhost:8090/health >/dev/null 2>&1; then
                log "Approval bridge running"
            else
                log "Warning: approval bridge failed to start"
            fi
        fi
    fi
}

# ── Helpers ──────────────────────────────────────────────────────────────────
_wait_for_litellm() {
    local max_wait=90
    local elapsed=0
    local auth_header=""
    [[ -n "${LITELLM_MASTER_KEY:-}" ]] && auth_header="Authorization: Bearer ${LITELLM_MASTER_KEY}"
    while ! curl -sf --max-time 2 "http://localhost:4000/health/liveliness" \
        ${auth_header:+-H "$auth_header"} >/dev/null 2>&1; do
        sleep 1
        ((elapsed++))
        if [[ $elapsed -ge $max_wait ]]; then
            log "Warning: LiteLLM did not become ready within ${max_wait}s"
            return 1
        fi
    done
}

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
    sandbox) cmd_sandbox "$@" ;;
    create) cmd_sandbox_new "$@" ;;  # backwards compat
    deploy) cmd_deploy "$@" ;;       # backwards compat
    stop)   cmd_stop ;;
    ps)     cmd_ps ;;
    health) cmd_health ;;
    verify-models) exec "${SCRIPT_DIR}/scripts/verify-models.sh" ;;
    env)    cmd_env ;;
    run)    cmd_run "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        cmd_help
        exit 1
        ;;
esac
