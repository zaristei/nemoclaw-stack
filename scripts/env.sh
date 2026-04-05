#!/usr/bin/env bash
# Source this file to set the stack environment for interactive use:
#   source scripts/env.sh
#
# After sourcing, openshell and nemoclaw commands will find the gateway,
# sandbox registry, and Docker socket created by stack.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

export STACK_ROOT="${STACK_ROOT:-/Volumes/macmini1}"
_STACK_DATA="${STACK_ROOT}/nemoclaw-stack"

export COLIMA_HOME="${_STACK_DATA}/colima"
export DOCKER_HOST="unix://${COLIMA_HOME}/default/docker.sock"
export XDG_CONFIG_HOME="${_STACK_DATA}/config"
export NEMOCLAW_HOME="${_STACK_DATA}/state/nemoclaw"

unset _STACK_DATA
