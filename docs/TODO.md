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

## Gateway-side policy audit log

Append-only log of every policy decision and lifecycle event (propose, approve, deny, activate, deactivate, fork) persisted in the gateway DB, not just the sandbox-local mediator audit log. Gateway becomes the system-of-record across sandbox restarts and multi-sandbox deployments.

Today the mediator's audit log lives inside the sandbox and dies with it. For compliance/forensics (who approved what, when, why) and cross-sandbox analysis, we need central persistence. Reference implementation exists on abandoned branch `fork/feat/mediator-fork-namespace` — migrations `004_create_policy_audit_log.sql` (postgres + sqlite) with schema: `id, sandbox_id, task_id, timestamp_ms, event_type, actor, justification, policy_version, policy_diff, context`.

Requires: server-side ingestion API, mediator daemon calls it on every policy state change, operator-facing query/export tool.

## Gateway-side approval webhooks

Generic HTTP approval webhook mechanism registered per-sandbox in the gateway DB. Replaces our Telegram-specific Python approval bridge with a gateway-native approval loop that any external system (Slack, PagerDuty, custom dashboard, a different messaging bot) can subscribe to.

Today approvals only flow through `scripts/approval-bridge.py` → Telegram. That bridge is a separate Python process that HMACs webhook payloads. Moving it into the gateway makes approval routing a first-class feature: one approval webhook URL per sandbox (with per-sandbox HMAC secret), subscribers decide policy via HTTP response, gateway enforces the decision. Reference schema on abandoned branch `fork/feat/mediator-fork-namespace` — migration `006_create_approval_webhooks.sql`: `id, sandbox_id UNIQUE, url, secret, created_at_ms, updated_at_ms`.

Requires: gateway registers/stores webhook config, mediator daemon calls gateway (not bridge) on `policy_propose`, gateway fans out to registered webhook, gateway routes response back to mediator.

## Force undici through L7 proxy via Node preload

OpenClaw's `web_fetch` tool uses undici's SSRF-guarded fetch path, which pre-resolves hostnames locally instead of letting the trusted L7 proxy resolve them. Result: every `web_fetch` call in a proxy-only sandbox fails with `getaddrinfo EAI_AGAIN`. Confirmed still broken on OpenClaw `2026.4.15` (v2026.4.8's `#59007` DNS-pinning-skip fix was scoped narrower than advertised — it only covers media-understanding paths, not web_fetch's guarded dispatcher; v2026.4.14's `#52162` added the same fix to a second site, evidence the fix doesn't generalize).

Workaround: drop a Node preload script that forces the process-wide undici dispatcher to a `ProxyAgent` pointing at `$HTTPS_PROXY`:

```js
// /sandbox/undici-proxy-preload.js
const { setGlobalDispatcher, ProxyAgent } = require('undici');
const uri = process.env.HTTPS_PROXY || process.env.HTTP_PROXY;
if (uri) setGlobalDispatcher(new ProxyAgent({ uri, requestTls: { rejectUnauthorized: false } }));
```

Inject in `scripts/sandbox-tools/agent-bootstrap.sh` via `export NODE_OPTIONS='--require /sandbox/undici-proxy-preload.js'` before `exec openclaw agent`. Every undici call in the child OpenClaw process (including `web_fetch`'s SSRF-guarded path) routes through our L7 proxy, and the proxy does the DNS resolution.

Also file upstream issue with OpenClaw: request that `web_fetch`'s SSRF-guarded fetch dispatcher honor `NODE_USE_ENV_PROXY` / `HTTPS_PROXY` the same way media-understanding now does (post-`#52162`). The monkey-patch becomes dead code once upstream merges the fix.

## Hybrid data-flow classification: explicit tags override TrustSpec heuristics

The simplified mediator launches with shape-inference classification only — `trust_spec.rs` reads a sandbox-level `TrustSpec` config that maps hosts and paths to data-flow classes (pii / non_pii, trusted / untrusted, internal / external). Every policy's endpoints and mounts get classified by matching against this config. The wizard and operator have no way to assert "this specific endpoint is trusted in this context despite its shape," which means borderline cases either require editing the global `TrustSpec` or getting the heuristic to match by luck.

Target: extend `NetworkEndpoint` and every filesystem entry in the policy schema with an optional `data_flow: { sensitivity, trust, locality }` block. When present on a node, the analyzer uses those values and skips the TrustSpec lookup for that node. When absent, fall back to TrustSpec-based inference (today's behavior).

Wizard UX: the wizard's system prompt already knows the three axes; it just needs to emit the block into the YAML when a case warrants an explicit override. Presets become simpler to author: each preset endpoint can declare its `data_flow` once, and every proposal referencing that preset inherits the tags.

Migration: purely additive. Existing policies without tags continue to classify via TrustSpec; new policies can opt in per-endpoint. No schema break, no operator retraining required.

## Per-UID Landlock carving as defense-in-depth on top of GID permissions

Today, per-workflow filesystem isolation is enforced via POSIX group permissions: `setup_instance_dir` chgrps each `external_mount` to the child's per-policy GID and sets group-mode bits matching the policy's `mode` field (`"r"` / `"rw"` / `"rx"` / `"rwx"`). Peer children running under different GIDs can't read each other's dirs. This is the mechanism that delivers subpath carving today.

Target: add a second enforcement layer via per-UID Landlock applied in `Command::pre_exec` before `setpriv` runs. Semantic benefit over permissions: children can't even `stat(2)` peer paths — the kernel returns ENOENT rather than EACCES. Hides the existence of sibling workflows entirely.

Non-trivial piece: the child's Landlock ruleset must preserve the sandbox's baseline paths (`/usr`, `/lib`, `/bin`, workspace init files, etc.) so `exec` and runtime linking continue to work, while narrowing the user-visible paths to the child's declared `external_mounts`. Upstream's existing `landlock.rs::prepare` takes a `SandboxPolicy`; we'd synthesize one per child as `(sandbox.read_only + sandbox.read_write) ∪ (child.external_mounts narrowed by mode)`. Apply via `restrict_self` in a `pre_exec` closure before the `setpriv` exec.

Blockers: none. All the plumbing is in place (subset check gates the child's requested paths at propose time; sandbox's baseline Landlock is already applied at startup). This is strictly a code increment on `fork_with_policy::setup_instance_dir` + `child_runner::spawn_child_process` plus tests that a child actually sees ENOENT on a peer's dir.
