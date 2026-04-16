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

## IPC result delivery (ipc_recv) — currently using file-based MVP

**MVP (current):** Children write results to `/sandbox/.mediator/results/<workflow_id>.json`. Parent reads the file after child exits. No scrubbers in the path — taint propagates. Acceptable for now because the parent explicitly asked for this data.

**Target architecture:** Scrubber processes as Unix-style filters. The mediator pipes IPC messages through a scrubber process (running under its own UID/policy) before delivering to the parent. `ipc_send` and `ipc_connect` are disabled until this is built.

Children can't send data back to the parent via IPC. Direct file reads bypass scrubbers and propagate taint. The correct pattern is message-queue style IPC with scrubbers in the path:

1. Child calls `ipc_send` with result after task completes
2. Message passes through the policy's configured scrubber (`de_taints: true` scrubbers break the taint chain)
3. Parent calls `ipc_recv` (new syscall) to read the scrubbed message

The bootstrap script should auto-send the child's stdout via `ipc_send` on exit. `ipc_connect` (socket pair / bidirectional stream) is for real-time collaboration between concurrent agents, not async result delivery.

## Registerable scrubbers

The 8 built-in scrubbers (regex_pii, field_pii, ner_pii, schema_enforcer, canary, delimiter, instruction_strip, passthrough) are hardcoded. Agents and operators should be able to register new scrubbers via a proposal flow, similar to policy_propose.

A `scrubber_propose` syscall would let an agent define a custom scrubber (e.g. a domain-specific PII filter, a format converter, or a content classifier) and attach it to an IPC channel. The operator approves the scrubber definition, which includes: name, type (wasm? regex set? JSON schema?), whether it `de_taints`, and the scrubber code/config itself.

This matters because the trifecta rule depends on scrubbers to break taint chains. If the only scrubbers are the 8 built-ins, agents are limited to generic patterns. Custom scrubbers let agents propose task-specific data gates — e.g. "only pass through fields matching this JSON schema" or "strip everything except the nutritional data table."

## external_mounts enforcement

TODO in fork_with_policy.rs: daemon declares mounts in policy schema but never actually sets group permissions on mount paths. Plumbing exists (`_gid`, `_external_mounts`), needs the chmod/chgrp loop.
