# Mediator Design Principles

**Audience:** NemoClaw core team
**Author:** Zack Aristei
**Date:** April 2026

---

## The Problem

An AI agent with access to customer records, web browsing, and an external API is one prompt injection away from exfiltrating data. Today's defense is behavioral — the system prompt says "don't leak data." This fails when:

1. The LLM is jailbroken via prompt injection (embedded in web pages, emails, user messages)
2. The agent reasons itself into sharing data ("the user asked for it, so it must be okay")
3. A multi-step chain combines innocent operations into a data leak (read file → summarize → send summary to untrusted endpoint)

System prompt guardrails are not a security boundary. They're suggestions to a statistical model.

## The Thesis

**Structural enforcement beats behavioral enforcement.** Instead of telling the model not to leak data, make it physically impossible by ensuring the model never receives the raw data in the first place. The sensitive fields are `[REDACTED]` before they reach inference. A fully jailbroken LLM cannot output a customer's SSN if the string `291-38-4756` never appeared in its context window.

## Why Syscalls

We call them syscalls because the analogy is precise. In an operating system:

- A process cannot directly access hardware. It makes a syscall, the kernel validates the request against the process's permissions, and either performs the operation or returns `EPERM`.
- The process runs in userspace. The kernel runs in a privileged ring. The boundary is enforced by hardware (ring transitions, page tables), not by asking the process nicely.

In the mediator:

- An agent cannot directly access data, the network, or other agents. It makes a syscall over a Unix domain socket, the mediator validates the request against the caller's policy, and either performs the operation or returns an error.
- The agent runs as a sandboxed process. The mediator runs as a privileged daemon. The boundary is enforced by UID isolation, iptables, filesystem permissions, and seccomp — not by the system prompt.

The syscall metaphor communicates the correct mental model to both the agent (via the system prompt) and the developer (via the API). These are not optional suggestions. They are the only way to perform cross-boundary operations.

### The 11 Syscalls

| Syscall | Kernel Analogy | Why It's Mediated |
|---------|---------------|-------------------|
| `http_request` | `connect()` + `send()` | Network egress is the primary exfiltration channel |
| `policy_propose` | `exec()` with new capabilities | Capability acquisition must be human-approved |
| `policy_list` | `ls /proc/` | Discovery of available capabilities |
| `policy_get` | `cat /proc/pid/status` | Inspection before use |
| `revoke_policy` | `kill -9` a capability set | Operator override, revocation propagates |
| `fork_with_policy` | `fork()` + `setuid()` | Child processes get scoped UIDs, GIDs, iptables |
| `signal` | `kill()` | Process lifecycle management |
| `request_port` | `bind()` | Inbound traffic is an untrusted input channel |
| `ipc_send` | `write()` to a pipe | Cross-process data flow with scrubbing |
| `ipc_connect` | `socketpair()` | Bidirectional streams with policy enforcement |
| `ps` | `readdir(/proc/)` | Scoped discovery (only see what your policy allows) |

### What Doesn't Need a Syscall

File I/O within a workflow's own mounts. Once `fork_with_policy` provisions the filesystem via Landlock + POSIX ACLs, the workflow operates at native speed. We tried mediating file access (`access_external_mount` was in early designs) and removed it — the overhead was prohibitive and the security comes from the provisioning, not per-operation checks.

## Policy Lifecycle

### Immutability

Policies are immutable. Once `research_scraper_v1` is approved, it cannot be modified. To change capabilities, the agent proposes `research_scraper_v2`. This eliminates:

- Mid-flight mutation bugs (children on v1 don't suddenly get v2's permissions)
- Ambiguous audit trails ("what policy was active when this data was accessed?")
- Race conditions between policy updates and running workflows

The version is in the name, not in metadata. `v1` and `v2` are different policies that can coexist. Old workflows keep running on old policies.

### Control Flow

```
Agent identifies a capability gap
  ↓
policy_list → check if an existing policy covers the need
  ↓
policy_get → inspect the candidate's allowlists and scrubbers
  ↓
If suitable: fork_with_policy → child starts immediately (no approval needed)
If not: policy_propose → mediator runs taint analysis
  ↓
Taint analysis: per-data-type-tag, checks source/untrusted/sink
  ↓
Results sent to approval bridge → operator sees:
  - The proposed policy config
  - Taint warnings (if any trifecta violations)
  - Which existing policies would be affected
  ↓
Operator approves or denies (Telegram inline button)
  ↓
If approved: policy stored, agent can now fork children with it
If denied: agent gets an error, must redesign
```

The key insight: **approval happens once per policy, not once per action.** The operator reviews the capability set and the taint analysis, then the agent operates autonomously within those bounds. This is analogous to installing an app (review permissions once) vs. prompting for every file access.

### The Proactive vs. Reactive Loop

The agent guide teaches two modes:

**Proactive:** The agent analyzes the task, identifies what policies it needs, proposes them upfront, waits for approval, then executes. Fewer round-trips, smoother UX.

**Reactive:** The agent tries an operation, gets denied, interprets the error, acquires the capability, retries. Works when the agent can't predict everything upfront.

In practice, both modes combine. The agent plans proactively for the main workflow and handles surprises reactively.

## The Lethal Trifecta

### Definition

A policy violates the lethal trifecta if, for the same data-type tag T, it simultaneously has:

1. **Source(T):** Can access sensitive data of type T (via mounts, unscrubbed IPC from a partner with source, or filesystem edge from a clean writer)
2. **Untrusted input(T):** Can receive attacker-controlled content tagged T (via HTTP to untrusted sources, `bind_ports`, or unscrubbed IPC from a partner with untrusted input)
3. **Sink(T):** Can exfiltrate data of type T (via HTTP to endpoints not in `trusted_external` for T, or unscrubbed IPC to a partner with sink)

### Why Per-Tag

A policy that has `source(pii)` and `sink(credentials)` is NOT a trifecta violation. The PII can't leak through the credentials sink because they're different data types. The analysis tracks each tag independently: pii, credentials, financial, web_content, internal, etc.

This prevents false positives. A logging endpoint trusted for PII doesn't need to be trusted for web_content. An untrusted web source tagged `web_content` doesn't contaminate a policy that only handles `credentials`.

### Guarantees

**If the taint analysis reports no trifecta, then:**

For every data-type tag T, there is no execution path where data classified as T can flow from a sensitive source, through a process that also handles untrusted content of type T, to an untrusted external endpoint for type T.

**What breaks this guarantee:**

1. The trust spec is wrong (a path is classified as non-sensitive when it actually contains PII)
2. A scrubber is bypassed (the scrubber claims `de_taints: true` but doesn't actually remove the data)
3. A side channel exists (timing, existence queries, error messages that reveal data)
4. The data is exfiltrated through a channel the mediator doesn't control (e.g., a binary exploit that bypasses seccomp)

The guarantee is against the **policy-level data flow**, not against all possible attacks. It's defense-in-depth, not a proof of security.

### Implicit Sensitivity

Data written to disk by a process with no untrusted input is presumed sensitive. The reasoning: if a process only handles trusted data (user conversations, database queries, internal computation), everything it writes is derived from trusted sources. Any other process reading those files inherits the sensitivity.

Conversely, data written by a process with untrusted input (web fetcher, webhook listener) is considered contaminated. Readers of that data get `untrusted_input`, not `source`.

This eliminates the need to manually tag workspace paths. The classification is derived from the writer's policy profile.

## Scrubbers as Taint Transformers

Scrubbers sit on IPC channels and transform data flowing between policies. They serve two roles:

### 1. Data Protection (PII scrubbing)

`regex_pii`, `field_pii`, and `ner_pii` remove personally identifiable information from messages before they cross a trust boundary. The receiving policy sees `[REDACTED]` where the SSN was.

These scrubbers set `de_taints: true`, which tells the taint analysis: "after this scrubber, the data is no longer considered source(T) for the specified tags." This is how IPC channels can cross trust boundaries without creating a trifecta.

### 2. Injection Defense (content scrubbing)

`instruction_strip`, `delimiter`, and `canary` defend against prompt injection in untrusted content. They do NOT set `de_taints: true` — they're defense-in-depth, not guarantees. A heuristic regex cannot catch all injection phrasings.

The design philosophy: PII scrubbers are **taint transformers** (they change the data's classification). Injection scrubbers are **defense layers** (they reduce risk without changing classification).

### 3. Structural Enforcement (schema)

`schema_enforcer` rejects messages that don't conform to a declared JSON schema. This constrains the attack surface — the receiving policy only accepts data in the expected shape.

## Init: The Coordinator Pattern

Init is the root process. In earlier designs, init had wildcard permissions (HTTP, IPC, mounts, ports). This made it a permanent trifecta violation.

The current design: init has **no HTTP access** except the inference endpoint. No sensitive mounts. No bind_ports. It coordinates by forking children with scoped policies and communicating via IPC. Results come back scrubbed.

```
Init (no data access, inference only)
  ├─ fork: customer_reader_v1 (mounts /data/customers, scrubbed IPC out)
  ├─ fork: email_reader_v1 (mounts /data/email, scrubbed IPC out)
  └─ fork: financial_monitor_v1 (mounts /data/financial, scrubbed IPC out)
```

Init reasons about scrubbed data. It can say "Sarah Chen has a balance of $84,230" but it cannot say "her SSN is 291-38-4756" because that string was `[REDACTED]` before it reached inference.

The inference endpoint is classified as `trusted_external` for all data types because init uses a key scoped to sensitive-tier models (zero-data-retention providers only).

## Separation of Concerns

The golden rule: **never combine all three trifecta legs in one policy.** The agent guide teaches decomposition patterns:

**Reader → Processor → Sender:** The reader has source, the sender has sink, the processor has neither. Scrubbers on the IPC channels between them strip PII.

**Fetcher → Analyzer:** The fetcher has untrusted input + sink but no source. The analyzer has source but no untrusted input (content is delimited/stripped on ingress) and no untrusted sink.

These patterns are not unique to our system — they're the principle of least privilege applied to data flow, not just capability. The mediator makes the principle enforceable rather than advisory.

## What This Enables for NemoClaw

### Multi-Agent Task Decomposition

An agent that needs to "research quantum computing using web sources and cross-reference against our internal knowledge base" can decompose this into:

- A web fetcher (untrusted HTTP, no sensitive data)
- A KB reader (sensitive data, no untrusted HTTP)
- A coordinator (inference only, scrubbed results from both)

Each child is a separate UID with its own iptables rules, Landlock profile, and IPC scrubbers. The decomposition happens at the agent's initiative — the agent proposes the policies, the operator approves once, and the agent forks the children autonomously.

### Blueprint-Level Policy Presets

Common decomposition patterns can be pre-approved in the NemoClaw blueprint. A "research assistant" blueprint ships with reader, fetcher, and coordinator policies already approved. The agent forks them without waiting for operator approval.

### Cross-Sandbox Communication (future)

The same policy/IPC/scrubber model extends to cross-sandbox communication. Two NemoClaw instances in separate sandboxes could communicate via a gateway-mediated IPC channel with the same mutual consent and scrubbing semantics.

## Implementation Status

| Component | Status | Tests |
|-----------|--------|-------|
| 11 syscalls over UDS | Complete | 141 unit + 10 integration |
| Per-tag taint analysis | Complete | 10 trifecta e2e |
| 8 scrubber types | Complete | 27 unit |
| Implicit sensitivity | Complete | 3 unit |
| mediator-daemon binary | Complete | Deployed to sandbox |
| mediator-cli binary | Complete | Deployed to sandbox |
| NemoClaw entrypoint hook | Complete | Backward compatible |
| Trust spec loading | Complete | YAML config |
| Compromise materialization | Complete | Fork-time bulk insert |
| Taint dashboard (vis.js) | Complete | HTTP server |
| Agent syscall guide | Complete | 467 lines |
| Doc workflow e2e tests | Complete | 5 scenarios |
| Full-stack e2e test | Complete | All workflows in one |
| WhatsApp honeypot | Complete | Live red team testing |
| **Total tests** | **167** | All passing |
