#!/usr/bin/env bash
# Import LiteLLM secrets from .env into macOS Keychain.
#
# Usage:
#   ./scripts/store-secrets.sh              # import from services/litellm/.env
#   ./scripts/store-secrets.sh --delete     # remove all entries from Keychain
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LITELLM_ENV="${SCRIPT_DIR}/../services/litellm/.env"
KEYCHAIN_SERVICE="nemoclaw-stack"

SECRET_KEYS=(
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    GOOGLE_API_KEY
    XAI_API_KEY
    MISTRAL_API_KEY
    OPENROUTER_API_KEY
    LITELLM_MASTER_KEY
)

if [[ "${1:-}" == "--delete" ]]; then
    for key in "${SECRET_KEYS[@]}"; do
        if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$key" &>/dev/null; then
            security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$key" &>/dev/null
            echo "  Deleted: $key"
        else
            echo "  Not found: $key"
        fi
    done
    echo "Done."
    exit 0
fi

if [[ ! -f "$LITELLM_ENV" ]]; then
    echo "Error: $LITELLM_ENV not found." >&2
    exit 1
fi

source "$LITELLM_ENV"

stored=0
skipped=0
for key in "${SECRET_KEYS[@]}"; do
    val="${!key:-}"
    if [[ -z "$val" ]]; then
        echo "  Skipped (empty): $key"
        ((skipped++))
        continue
    fi
    # Delete existing entry if present, then add new one
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$key" &>/dev/null || true
    security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$key" -w "$val"
    echo "  Stored: $key"
    ((stored++))
done

echo "Done. Stored: $stored, Skipped: $skipped"
