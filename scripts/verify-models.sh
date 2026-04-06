#!/usr/bin/env bash
# Verify all model IDs in the LiteLLM config against live provider APIs.
#
# Usage:
#   ./scripts/verify-models.sh              # verify all models
#   ./scripts/verify-models.sh --fix        # verify and remove "# verify" comments for passing models
#
# Requires: LiteLLM running on https://localhost:4000, API keys in env.
# Run after: ./stack.sh start
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
MODELS_FILE="${REPO_DIR}/services/litellm/config/models.yaml"
STACK_DATA="${STACK_ROOT:-/Volumes/macmini1}/nemoclaw-stack"

FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

# ── Resolve secrets ─────────────────────────────────────────────────────
source "${SCRIPT_DIR}/resolve-secrets.sh"

LITELLM_BASE="https://localhost:4000"
LITELLM_KEY="${LITELLM_MASTER_KEY:-}"
OR_KEY="${OPENROUTER_API_KEY:-}"

if [[ -z "$LITELLM_KEY" ]]; then
    echo "Error: LITELLM_MASTER_KEY not set" >&2
    exit 1
fi

# Check LiteLLM is running
if ! curl -sfk --max-time 5 "${LITELLM_BASE}/health/liveliness" \
    -H "Authorization: Bearer ${LITELLM_KEY}" >/dev/null 2>&1; then
    echo "Error: LiteLLM not reachable at ${LITELLM_BASE}" >&2
    echo "Run ./stack.sh start first." >&2
    exit 1
fi

# ── Extract model IDs from YAML ─────────────────────────────────────────
# Parse all unique model IDs and their tier names
models=$(python3 -c "
import yaml, sys

with open('$MODELS_FILE') as f:
    content = f.read()

# Parse YAML (anchors get resolved automatically)
data = yaml.safe_load(content)

seen = set()
for entry in data.get('model_list', []):
    params = entry.get('litellm_params', {})
    model = params.get('model', '')
    tier = entry.get('model_name', '')
    if model and (model, tier) not in seen:
        seen.add((model, tier))
        print(f'{tier}|{model}')
" 2>/dev/null)

if [[ -z "$models" ]]; then
    echo "Error: no models found in ${MODELS_FILE}" >&2
    exit 1
fi

# ── Test each model ──────────────────────────────────────────────────────
total=0
ok=0
fail=0
failed_models=()
verified_models=()

echo "=== Model ID Verification ==="
echo "  Testing each model against live APIs via LiteLLM..."
echo ""

while IFS='|' read -r tier model; do
    [[ -z "$model" ]] && continue
    ((total++))

    # For OpenRouter models, also check the model exists on OpenRouter directly
    or_check=""
    if [[ "$model" == openrouter/* ]]; then
        or_model="${model#openrouter/}"
        if [[ -n "$OR_KEY" ]]; then
            # Quick check: does OpenRouter know this model?
            or_resp=$(curl -sk --max-time 10 "https://openrouter.ai/api/v1/models" \
                -H "Authorization: Bearer ${OR_KEY}" 2>/dev/null)
            if echo "$or_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ids = [m['id'] for m in data.get('data', [])]
sys.exit(0 if '${or_model}' in ids else 1)
" 2>/dev/null; then
                or_check=" [OR: listed]"
            else
                or_check=" [OR: NOT FOUND in model list]"
            fi
        fi
    fi

    # Test via LiteLLM with a minimal completion
    resp=$(curl -sk --max-time 30 "${LITELLM_BASE}/v1/chat/completions" \
        -H "Authorization: Bearer ${LITELLM_KEY}" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${tier}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"respond with only the word pong\"}],
            \"max_tokens\": 5
        }" 2>&1)

    content=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['choices'][0]['message']['content'])" 2>/dev/null || true)
    served=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model','?'))" 2>/dev/null || echo "?")
    error=$(echo "$resp" | python3 -c "import sys,json; e=json.load(sys.stdin).get('error',{}); print(e.get('message','')[:120] if e else '')" 2>/dev/null || true)

    if [[ -n "$content" ]]; then
        echo "  ✓ ${model}"
        echo "    tier: ${tier} | served by: ${served}${or_check}"
        ((ok++))
        verified_models+=("$model")
    else
        echo "  ✗ ${model}"
        echo "    tier: ${tier} | error: ${error:-no response / timeout}${or_check}"
        ((fail++))
        failed_models+=("$model")
    fi
done <<< "$models"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Total: ${total} | Passed: ${ok} | Failed: ${fail}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#failed_models[@]} -gt 0 ]]; then
    echo ""
    echo "  Failed models (may cause mid-conversation errors):"
    for m in "${failed_models[@]}"; do
        echo "    - ${m}"
    done
    echo ""
    echo "  Action: fix model IDs in ${MODELS_FILE} and rebuild:"
    echo "    python3 scripts/build_litellm_config.py"
fi

# ── Fix mode: remove "# verify" from passing models ─────────────────────
if [[ "$FIX" -eq 1 ]] && [[ ${#verified_models[@]} -gt 0 ]]; then
    echo ""
    echo "=== Fixing verified models ==="
    fixed=0
    for m in "${verified_models[@]}"; do
        # Escape for sed
        escaped=$(printf '%s\n' "$m" | sed 's/[[\.*^$()+?{|]/\\&/g')
        # Remove "# verify" comment on lines containing this model
        if grep -q "${escaped}.*# verify" "$MODELS_FILE" 2>/dev/null; then
            sed -i '' "s|\(${escaped}\).*# verify.*|\1|" "$MODELS_FILE" 2>/dev/null || \
            sed -i "s|\(${escaped}\).*# verify.*|\1|" "$MODELS_FILE" 2>/dev/null || true
            echo "  ✓ Removed '# verify' from: ${m}"
            ((fixed++))
        fi
    done
    if [[ $fixed -gt 0 ]]; then
        echo ""
        echo "  ${fixed} model(s) verified. Rebuild config:"
        echo "    python3 scripts/build_litellm_config.py"
    else
        echo "  No '# verify' comments to remove."
    fi
fi

# Exit with failure if any models failed
[[ $fail -eq 0 ]]
