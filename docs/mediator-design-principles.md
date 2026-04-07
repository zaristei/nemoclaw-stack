# Mediator Design Principles

**Audience:** NemoClaw core team
**Author:** Zack Aristei
**Date:** April 2026

---

## The Core Idea: Agents Should Design Their Own Security

Today, an operator defines a static network policy before the agent starts. The agent runs within those bounds or gets blocked. This works for known workflows but fails when the agent encounters something new — it hits a wall, the operator gets paged, manual intervention follows.

The mediator inverts this. **The agent proposes its own security policies at runtime.** It analyzes the task, determines what data and network access it needs, designs a policy that avoids the lethal trifecta, and submits it for approval. The operator reviews a structured security proposal, not a raw URL allowlist request. The agent operates autonomously within the approved bounds.

This is the difference between "the agent runs inside a predefined box" and "the agent designs the box, the operator validates the design, and the agent builds the box around itself."

### Why This Matters

An autonomous agent that can't acquire new capabilities is limited to what the operator anticipated. An agent that can propose policies adapts to novel tasks:

- User asks the agent to research a new topic → agent proposes a fetcher policy with the relevant URLs
- Agent discovers it needs access to a new database → proposes a reader policy with the appropriate mounts and scrubbers
- Agent needs to parallelize work → proposes child policies with scoped access for each subtask
- Agent hits a rate limit on one provider → proposes a v2 policy with a different endpoint

The operator doesn't need to predict every possible task. They review and approve policy proposals as they arise. The approval is structural (reviewing a policy config + taint analysis) not behavioral (reviewing individual HTTP requests).

### The Approval Model

```
Agent identifies need → policy_propose → taint analysis runs → operator reviews
                                                                     ↓
                                            Sees: policy config, trifecta warnings,
                                            affected existing policies, scrubber gaps
                                                                     ↓
                                                            Approve / Deny
                                                                     ↓
                                            Agent forks children with approved policy
                                            (no further approval needed per action)
```

**Approve once, run many.** The operator reviews the capability set and its security implications, then the agent operates autonomously within those bounds. This is analogous to reviewing app permissions at install time vs. prompting for every file access.

### Immutability Enables Trust

Policies are immutable. `research_scraper_v1` cannot be modified after approval. To change capabilities, the agent proposes `v2`. This gives the operator confidence that what they approved is what's running — there's no drift between the approved policy and the active policy.

It also means the agent can reason about its own policy tree. It knows `v1` children have specific capabilities, `v2` children have different ones, and both can coexist. The audit trail is unambiguous.

## Why Syscalls

We call them syscalls because the analogy is precise. In an operating system:

- A process cannot directly access hardware. It makes a syscall, the kernel validates against the process's permissions, and either performs the operation or returns `EPERM`.
- The boundary is enforced by hardware (ring transitions, page tables), not by asking the process nicely.

In the mediator:

- An agent cannot directly access data, the network, or other agents. It makes a syscall over a Unix domain socket, the mediator validates against the caller's policy, and either performs the operation or returns an error.
- The boundary is enforced by UID isolation, iptables, filesystem permissions, and seccomp — not by the system prompt.

### The 11 Syscalls

| Syscall | Kernel Analogy | Why It's Mediated |
|---------|---------------|-------------------|
| `http_request` | `connect()` + `send()` | Network egress is the primary exfiltration channel |
| `policy_propose` | `exec()` with new capabilities | The agent designs its own security policies |
| `policy_list` | `ls /proc/` | Discovery — check what's available before proposing |
| `policy_get` | `cat /proc/pid/status` | Inspect a policy's scrubbers and allowlists before forking |
| `revoke_policy` | `kill -9` a capability set | Operator override, revocation propagates to all children |
| `fork_with_policy` | `fork()` + `setuid()` | Child gets its own UID, GID, iptables, Landlock |
| `signal` | `kill()` | Lifecycle management (term, kill, stop, cont) |
| `request_port` | `bind()` | Inbound traffic is an untrusted input channel |
| `ipc_send` | `write()` to a pipe | Cross-process data flow with scrubbing |
| `ipc_connect` | `socketpair()` | Bidirectional streams with policy enforcement |
| `ps` | `readdir(/proc/)` | Scoped discovery (only see what your policy allows) |

The policy CRUD syscalls (`propose`, `list`, `get`, `revoke`) are the distinctive ones. They don't exist in a traditional OS because processes don't design their own permissions. Here, the agent is expected to — that's the point.

### What Doesn't Need a Syscall

File I/O within a workflow's own mounts. Once `fork_with_policy` provisions the filesystem via Landlock + POSIX ACLs, the workflow operates at native speed. We tried mediating file access and removed it — the overhead was prohibitive and the security comes from provisioning, not per-operation checks.

## The Lethal Trifecta

### Definition

A policy violates the lethal trifecta if, for the same data-type tag T, it simultaneously has:

1. **Source(T):** Access to sensitive data of type T
2. **Untrusted input(T):** Receives attacker-controlled content tagged T
3. **Sink(T):** Can send data to an endpoint not trusted for type T

### Why Per-Tag

A policy with `source(pii)` and `sink(credentials)` is NOT a violation. The PII can't leak through the credentials sink — they're different data types. The analysis tracks each tag independently.

### The Guarantee

**If the taint analysis reports no trifecta, then:** For every data-type tag T, there is no policy-level execution path where data of type T flows from a sensitive source, through a process handling untrusted content of type T, to an untrusted external endpoint for type T.

**What this doesn't cover:** Side channels, scrubber bugs, trust spec misclassification, binary exploits. The guarantee is against policy-level data flow, not all possible attacks.

### Implicit Sensitivity

Data written by a process with no untrusted input is presumed sensitive. A clean process only handles trusted data — everything it writes is derived from trusted sources. This eliminates manual workspace tagging. The classification is derived from the writer's policy profile.

### How Dynamic Policy Creation Interacts With Trifecta

When the agent proposes a policy, the taint analysis runs **before** the operator sees it. The proposal includes:

- The policy config
- Per-tag taint classification (source/untrusted/sink for each data type)
- Whether any tag has all three legs (trifecta violation)
- Which **existing** policies would be affected (their taint worsens if this policy is approved)
- Pre-computed compromised resources that would be materialized at fork time

The agent can propose a trifecta-violating policy. The operator will see a big red warning. They can approve it anyway (informed risk) or deny it (agent must redesign).

The agent guide teaches the agent to **avoid trifecta proactively** by decomposing work:

```
BAD:  one policy with sensitive data + untrusted HTTP + external sink
GOOD: reader policy (data, scrubbed IPC out) + fetcher policy (HTTP, no data)
```

The agent learns to design safe policies the same way a developer learns to write secure code — by understanding the principles and applying them. The difference is the taint analysis catches mistakes at proposal time, not at breach time.

## Scrubbers as Taint Transformers

Scrubbers sit on IPC channels between policies. They come in two flavors:

**Taint transformers** (`de_taints: true`): `regex_pii`, `field_pii`, `ner_pii`, `schema_enforcer`. These change the data's classification — after scrubbing, the data is no longer `source(T)` for the specified tags. This is how IPC channels cross trust boundaries without creating trifecta.

**Defense layers** (`de_taints: false`): `instruction_strip`, `delimiter`, `canary`. These reduce injection risk without changing classification. A heuristic regex can't catch all injection phrasings, so the taint analysis doesn't trust them to break the chain.

The agent specifies scrubbers per-IPC-target in its policy proposal:

```yaml
allowed_ipc_targets:
  - policy_name: "processor_*"
    scrub_egress:
      scrubber: field_pii
      data_types: [pii]
      de_taints: true
      config:
        fields: ["$.email", "$.ssn", "$.phone"]
        action: redact
```

This means: "I want to talk to processor policies, and when I send data, scrub these PII fields first." The operator sees this in the proposal and can verify the scrubber coverage matches the data sensitivity.

## The Init Coordinator Pattern

Init is the root agent process. In earlier designs it had wildcard permissions — HTTP, IPC, mounts, everything. This made it a permanent trifecta violation.

Current design: init has **no HTTP except the inference endpoint**, no sensitive mounts, no bind_ports. It coordinates by forking children with scoped policies. Results come back scrubbed.

This means the LLM — the most attackable component (prompt injection, jailbreaks) — never touches raw PII. It reasons about `[REDACTED]` data. Even a fully compromised model can't leak what it never received.

The inference endpoint is classified as trusted because init uses a key scoped to zero-data-retention providers. The trust classification of the inference URL is what closes the sink leg.

## What This Enables

### Self-Organizing Agent Workflows

The agent doesn't need a predefined workflow. It receives a task, analyzes what capabilities it needs, proposes policies, and builds the workflow at runtime. A "research quantum computing" task becomes:

1. Agent proposes `fetcher_v1` (arxiv HTTP, scrubbed IPC to coordinator)
2. Agent proposes `kb_reader_v1` (internal KB mount, scrubbed IPC)
3. Operator approves both (taint analysis: no trifecta)
4. Agent forks both, coordinates via IPC, collects scrubbed results

Next time the agent gets a similar task, the policies already exist. `policy_list` shows them, `policy_get` confirms they fit, `fork_with_policy` creates children immediately — no approval round-trip.

### Blueprint Policy Presets

Common patterns can be pre-approved in the NemoClaw blueprint. A "research assistant" blueprint ships with reader, fetcher, and coordinator policies. The agent forks them without waiting. The operator approved the blueprint once.

### Graduated Autonomy

New agents start with no pre-approved policies. Every capability requires operator approval. As trust builds, the operator pre-approves more policies in the blueprint. Eventually the agent operates fully autonomously within a rich policy set, only proposing new policies for genuinely novel tasks.

### Cross-Sandbox Communication (Future)

The same policy/IPC/scrubber model extends to cross-sandbox channels. Two NemoClaw instances could communicate via gateway-mediated IPC with mutual consent and scrubbing — the same semantics, different transport.

## Implementation Status

| Component | Status | Tests |
|-----------|--------|-------|
| 11 syscalls over UDS | Complete | 141 unit + 10 integration |
| Per-tag taint analysis | Complete | 10 trifecta e2e |
| 8 scrubber types | Complete | 27 unit |
| Implicit sensitivity | Complete | 3 unit |
| mediator-daemon + mediator-cli | Complete | Deployed to sandbox |
| NemoClaw entrypoint hook | Complete | Backward compatible |
| Agent syscall guide | Complete | 467 lines |
| Doc workflow e2e tests | Complete | 5 scenarios |
| Full-stack e2e test | Complete | 1 lifecycle test |
| WhatsApp honeypot | Complete | Live red team |
| **Total tests** | **167** | All passing |
