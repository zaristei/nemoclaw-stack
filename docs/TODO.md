# TODO

## Agent-accessible gateway + LiteLLM config

The agent should be able to read gateway and LiteLLM configuration from within the sandbox via appropriate mounts. Currently the agent has no visibility into what models are available, what tiers exist, or how routing works.

This enables cost tracking (#2) — the agent needs to know model costs, rate limits, and routing rules to make informed decisions about tool use and inference. Also needed for self-tuning: if the agent knows which models are cheap vs expensive, it can route subtasks appropriately.

Read-only mounts or a config-read syscall for LiteLLM config (model groups, cost metadata, rate limits). The agent should NOT be able to modify LiteLLM config directly — changes go through policy_propose.

## API usage tracking

Track inference + tool API usage for all services (LiteLLM tiers, Brave search, Claude subscription, OpenRouter, etc.) and expose it to the agent. The agent uses this to inform its tool use and inference decisions.

Without cost awareness, the agent will always pick the most capable model / most expensive tool. With usage data, it can balance cost vs capability — e.g. use haiku tier for simple tasks, save opus tier for complex reasoning. Also needed for operator billing visibility.

LiteLLM already tracks usage per model group. Need to: (a) expose usage metrics to the agent via a read-only mount or tool, (b) track non-LiteLLM API usage (Brave, etc.), (c) include Claude Code subscription limits if applicable. The mediator audit log already captures syscall usage.

## Upstream profiles as policy_propose presets

OpenShell/OpenClaw is introducing "profiles" — predefined capability bundles. These should be importable as presets for policy_propose, so the agent (or operator) can propose a policy by referencing a profile name instead of specifying every field manually.

Reduces boilerplate in policy proposals. Instead of specifying http_allowlist, mounts, launch commands etc. from scratch, the agent says "I need the 'web-researcher' profile" and the mediator fills in the details. Also enables operator-curated policy templates that enforce organizational standards.

When upstream profiles ship, map them to MediationPolicy templates. policy_propose gains an optional `profile` field that pre-fills config from a profile. The operator still approves — profiles reduce friction, not bypass approval.

## IPC result delivery

Children can't send data back to the parent. The agent identified this correctly during Telegram testing. Options: read child stdout from instance dir, or implement ipc_recv/ipc_reply.

## external_mounts enforcement

TODO in fork_with_policy.rs: daemon declares mounts in policy schema but never actually sets group permissions on mount paths. Plumbing exists (`_gid`, `_external_mounts`), needs the chmod/chgrp loop.
