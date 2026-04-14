#!/bin/sh
# agent-bootstrap.sh — set up an OpenClaw agent workspace and run --local
#
# Called by fork_with_policy as the child's launch command. Expects:
#   $WORKFLOW_ID    — set by the mediator daemon
#   $POLICY_NAME    — set by the mediator daemon
#   $MEDIATOR_TOKEN — set by the mediator daemon
#   $1              — the task message for the agent
#
# Sets up a per-policy shared workspace and per-workflow agent state dir,
# then runs openclaw agent --local under the child's UID.

POLICY_WORKSPACE="/sandbox/.mediator/policies/${POLICY_NAME}/workspace"
AGENT_DIR="/sandbox/.mediator/workflows/${WORKFLOW_ID}/agent"

# Create dirs if they don't exist (child UID owns workflow dir,
# policy GID owns workspace via setgid from fork_with_policy setup)
mkdir -p "$POLICY_WORKSPACE" "$AGENT_DIR/sessions" 2>/dev/null

# Register this workflow as an OpenClaw agent with isolated paths
openclaw agents add "$WORKFLOW_ID" \
  --workspace "$POLICY_WORKSPACE" \
  --agent-dir "$AGENT_DIR" \
  --non-interactive 2>/dev/null

# Run the agent turn
exec openclaw agent --agent "$WORKFLOW_ID" --local -m "$1" --json
