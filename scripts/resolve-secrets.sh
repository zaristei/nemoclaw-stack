#!/usr/bin/env bash
# Resolve LiteLLM secrets from the configured backend.
#
# Backends:
#   env      — source services/litellm/.env (default)
#   keychain — read from macOS Keychain (service: nemoclaw-stack)
#
# Usage (sourced by start.sh):
#   SECRETS_BACKEND=keychain source scripts/resolve-secrets.sh
#
# Each key is exported only if not already set in the environment,
# so explicit env var overrides always win.
set -euo pipefail

SECRETS_BACKEND="${SECRETS_BACKEND:-env}"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LITELLM_ENV="${_SCRIPT_DIR}/../services/litellm/.env"
_KEYCHAIN_SERVICE="nemoclaw-stack"

# Keys that LiteLLM needs at runtime
_SECRET_KEYS=(
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    GOOGLE_API_KEY
    XAI_API_KEY
    MISTRAL_API_KEY
    OPENROUTER_API_KEY
    LITELLM_MASTER_KEY
)

_resolve_from_env() {
    if [[ ! -f "$_LITELLM_ENV" ]]; then
        echo "Error: $_LITELLM_ENV not found. Copy from .env.example and fill in." >&2
        return 1
    fi
    set -a; source "$_LITELLM_ENV"; set +a
}

_resolve_from_keychain() {
    local key val missing=()
    for key in "${_SECRET_KEYS[@]}"; do
        # Skip if already set in environment
        if [[ -n "${!key:-}" ]]; then
            continue
        fi
        val=$(security find-generic-password -s "$_KEYCHAIN_SERVICE" -a "$key" -w 2>/dev/null) || true
        if [[ -n "$val" ]]; then
            export "$key=$val"
        else
            missing+=("$key")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Warning: missing Keychain entries for: ${missing[*]}" >&2
        echo "  Run: ./scripts/store-secrets.sh to populate from .env" >&2
    fi
}

case "$SECRETS_BACKEND" in
    env)
        _resolve_from_env
        ;;
    keychain)
        _resolve_from_keychain
        ;;
    *)
        echo "Error: unknown SECRETS_BACKEND '$SECRETS_BACKEND' (valid: env, keychain)" >&2
        exit 1
        ;;
esac
