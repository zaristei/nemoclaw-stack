#!/usr/bin/env bash
# Start nemoclaw-stack services via Colima + Docker Compose.
#
# Usage:
#   ./start.sh              # start all services
#   ./start.sh litellm      # start specific service
#   ./start.sh down          # stop everything
#   ./start.sh ps            # show status
set -euo pipefail

export COLIMA_HOME=/Volumes/macmini1/config/colima
export DOCKER_HOST=unix://${COLIMA_HOME}/default/docker.sock

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yml"

# Ensure docker-compose CLI plugin is linked
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

# Start Colima if not running
if ! colima status &>/dev/null; then
    echo "Starting Colima..."
    colima start
fi

# Rebuild litellm config if sources are newer than built output
BUILT="${SCRIPT_DIR}/services/litellm/config/litellm_config.built.yaml"
if [[ ! -f "$BUILT" ]] || \
   [[ "${SCRIPT_DIR}/services/litellm/config/models.yaml" -nt "$BUILT" ]] || \
   [[ "${SCRIPT_DIR}/services/litellm/config/litellm_config.yaml" -nt "$BUILT" ]] || \
   [[ "${SCRIPT_DIR}/services/litellm/config/trusted_providers.yaml" -nt "$BUILT" ]]; then
    echo "Rebuilding litellm config..."
    python3 "${SCRIPT_DIR}/scripts/build_litellm_config.py"
fi

# Dispatch
case "${1:-up}" in
    down)   $COMPOSE down "${@:2}" ;;
    ps)     $COMPOSE ps "${@:2}" ;;
    logs)   $COMPOSE logs "${@:2}" ;;
    up)     $COMPOSE up -d "${@:2}" ;;
    *)      $COMPOSE up -d "$@" ;;
esac
