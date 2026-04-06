#!/usr/bin/env bash
# Verify all model IDs in the LiteLLM config against live provider APIs.
#
# Tests each model individually (not by tier) to catch bad IDs that
# LiteLLM would route around. Exits non-zero if any model fails.
#
# Usage:
#   ./scripts/verify-models.sh           # verify all models
#
# Requires: API keys in env (source resolve-secrets.sh first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
MODELS_FILE="${REPO_DIR}/services/litellm/config/models.yaml"

# ── Resolve secrets ─────────────────────────────────────────────────────
source "${SCRIPT_DIR}/resolve-secrets.sh"

OR_KEY="${OPENROUTER_API_KEY:-}"

# ── Fetch OpenRouter model list once ────────────────────────────────────
OR_MODELS=""
if [[ -n "$OR_KEY" ]]; then
    OR_MODELS=$(curl -sk --max-time 15 "https://openrouter.ai/api/v1/models" \
        -H "Authorization: Bearer ${OR_KEY}" 2>/dev/null | \
        python3 -c "import sys,json; [print(m['id']) for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true)
fi

# ── Extract unique model IDs from YAML ──────────────────────────────────
models=$(python3 -c "
import yaml, sys

with open('$MODELS_FILE') as f:
    data = yaml.safe_load(f)

seen = set()
for entry in data.get('model_list', []):
    params = entry.get('litellm_params', {})
    model = params.get('model', '')
    tier = entry.get('model_name', '')
    api_key_ref = params.get('api_key', '')
    if model and model not in seen:
        seen.add(model)
        print(f'{model}|{tier}|{api_key_ref}')
" 2>/dev/null)

if [[ -z "$models" ]]; then
    echo "Error: no models found in ${MODELS_FILE}" >&2
    exit 1
fi

# ── Test each model directly against its provider ────────────────────────
total=0
ok=0
fail=0
failed_models=()

echo "=== Model ID Verification ==="
echo ""

while IFS='|' read -r model tier api_key_ref; do
    [[ -z "$model" ]] && continue
    ((total++))

    # Determine provider and test method
    if [[ "$model" == openrouter/* ]]; then
        # OpenRouter: check model list + test via OpenRouter API directly
        or_model="${model#openrouter/}"

        # Check if model exists in OpenRouter's catalog
        or_listed=false
        if [[ -n "$OR_MODELS" ]]; then
            if echo "$OR_MODELS" | grep -qx "$or_model"; then
                or_listed=true
            fi
        fi

        if [[ "$or_listed" == "false" ]] && [[ -n "$OR_MODELS" ]]; then
            echo "  ✗ ${model}"
            echo "    NOT FOUND in OpenRouter model list (tier: ${tier})"
            ((fail++))
            failed_models+=("$model")
            continue
        fi

        # Test with actual inference call
        if [[ -n "$OR_KEY" ]]; then
            resp=$(curl -sk --max-time 30 "https://openrouter.ai/api/v1/chat/completions" \
                -H "Authorization: Bearer ${OR_KEY}" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"${or_model}\",
                    \"messages\": [{\"role\": \"user\", \"content\": \"respond with only the word pong\"}],
                    \"max_tokens\": 5
                }" 2>&1)
        else
            echo "  ? ${model}"
            echo "    OPENROUTER_API_KEY not set — skipped (tier: ${tier})"
            continue
        fi

    elif [[ "$model" == openai/* ]]; then
        # OpenAI direct
        api_key="${OPENAI_API_KEY:-}"
        [[ -z "$api_key" ]] && { echo "  ? ${model} — OPENAI_API_KEY not set"; continue; }
        real_model="${model#openai/}"
        resp=$(curl -sk --max-time 30 "https://api.openai.com/v1/chat/completions" \
            -H "Authorization: Bearer ${api_key}" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"${real_model}\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with only the word pong\"}],\"max_tokens\":5}" 2>&1)

    elif [[ "$model" == gemini/* ]]; then
        # Google via LiteLLM format — test with Google's API
        api_key="${GOOGLE_API_KEY:-}"
        [[ -z "$api_key" ]] && { echo "  ? ${model} — GOOGLE_API_KEY not set"; continue; }
        real_model="${model#gemini/}"
        resp=$(curl -sk --max-time 30 "https://generativelanguage.googleapis.com/v1beta/models/${real_model}:generateContent?key=${api_key}" \
            -H "Content-Type: application/json" \
            -d "{\"contents\":[{\"parts\":[{\"text\":\"respond with only the word pong\"}]}],\"generationConfig\":{\"maxOutputTokens\":5}}" 2>&1)
        # Google has different response format
        content=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['candidates'][0]['content']['parts'][0]['text'])" 2>/dev/null || true)
        error=$(echo "$resp" | python3 -c "import sys,json; e=json.load(sys.stdin).get('error',{}); print(e.get('message','')[:120] if e else '')" 2>/dev/null || true)
        if [[ -n "$content" ]]; then
            echo "  ✓ ${model} (tier: ${tier})"
            ((ok++))
        else
            echo "  ✗ ${model}"
            echo "    error: ${error:-no response / timeout} (tier: ${tier})"
            ((fail++))
            failed_models+=("$model")
        fi
        continue

    elif [[ "$model" == xai/* ]]; then
        api_key="${XAI_API_KEY:-}"
        [[ -z "$api_key" ]] && { echo "  ? ${model} — XAI_API_KEY not set"; continue; }
        real_model="${model#xai/}"
        resp=$(curl -sk --max-time 30 "https://api.x.ai/v1/chat/completions" \
            -H "Authorization: Bearer ${api_key}" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"${real_model}\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with only the word pong\"}],\"max_tokens\":5}" 2>&1)

    elif [[ "$model" == mistral/* ]]; then
        api_key="${MISTRAL_API_KEY:-}"
        [[ -z "$api_key" ]] && { echo "  ? ${model} — MISTRAL_API_KEY not set"; continue; }
        real_model="${model#mistral/}"
        resp=$(curl -sk --max-time 30 "https://api.mistral.ai/v1/chat/completions" \
            -H "Authorization: Bearer ${api_key}" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"${real_model}\",\"messages\":[{\"role\":\"user\",\"content\":\"respond with only the word pong\"}],\"max_tokens\":5}" 2>&1)

    elif [[ "$model" == claude-* ]]; then
        # Anthropic (direct, uses Messages API)
        api_key="${ANTHROPIC_API_KEY:-}"
        [[ -z "$api_key" ]] && { echo "  ? ${model} — ANTHROPIC_API_KEY not set"; continue; }
        resp=$(curl -sk --max-time 30 "https://api.anthropic.com/v1/messages" \
            -H "x-api-key: ${api_key}" \
            -H "anthropic-version: 2023-06-01" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"${model}\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"respond with only the word pong\"}]}" 2>&1)
        # Anthropic response format
        content=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['content'][0]['text'])" 2>/dev/null || true)
        error=$(echo "$resp" | python3 -c "import sys,json; e=json.load(sys.stdin).get('error',{}); print(e.get('message','')[:120] if e else '')" 2>/dev/null || true)
        if [[ -n "$content" ]]; then
            echo "  ✓ ${model} (tier: ${tier})"
            ((ok++))
        else
            echo "  ✗ ${model}"
            echo "    error: ${error:-no response / timeout} (tier: ${tier})"
            ((fail++))
            failed_models+=("$model")
        fi
        continue

    else
        echo "  ? ${model} — unknown provider format (tier: ${tier})"
        continue
    fi

    # Generic OpenAI-format response parsing (for openai, xai, mistral, openrouter)
    content=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['choices'][0]['message']['content'])" 2>/dev/null || true)
    error=$(echo "$resp" | python3 -c "import sys,json; e=json.load(sys.stdin).get('error',{}); print(e.get('message','')[:120] if e else '')" 2>/dev/null || true)

    if [[ -n "$content" ]]; then
        echo "  ✓ ${model} (tier: ${tier})"
        ((ok++))
    else
        echo "  ✗ ${model}"
        echo "    error: ${error:-no response / timeout} (tier: ${tier})"
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
    echo "  Failed models:"
    for m in "${failed_models[@]}"; do
        echo "    - ${m}"
    done
    echo ""
    echo "  Fix model IDs in ${MODELS_FILE} and rebuild:"
    echo "    python3 scripts/build_litellm_config.py"
fi

# Exit non-zero if any model failed
[[ $fail -eq 0 ]]
