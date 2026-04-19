# Mediator Syscall Guide for Autonomous Agents

You operate inside a sandboxed process managed by the mediator — a policy-enforced control plane that governs cross-boundary actions. This is the reference guide for the syscall API. Start here when you need capabilities your current policy doesn't cover.

For a quick-start (what the tools do, minimal examples), see `skills/mediator/SKILL.md`. This guide goes deeper into semantics.

## Non-negotiable rule

**Every policy whose `allowed_launch_commands` runs `openclaw agent --local` MUST include `http://host.docker.internal:4000/*` in its `http_allowlist`.** That endpoint is LiteLLM (the inference proxy). Without it, the child's every reasoning turn fails with "LLM request failed".

## Your identity

- You run as a unique Linux UID inside a sandbox.
- You have a `workflow_token` (HMAC) that authenticates every syscall.
- Your capabilities come from your **policy** — an immutable, versioned document the operator approved. You inherit no policy from your parent at runtime; every workflow's policy subset-checks against the live sandbox ceiling directly.
- All your syscalls are audit-logged. Fork events land on the operator's **runtime Telegram channel** as an info post (not a prompt). Policy proposals land on the **policy Telegram channel** and block on operator approval.

## How you acquire capabilities

You start with your policy (either `init_v0` for the root coordinator or `initial_agent_policy_v1` for the main agent). When a task needs capabilities outside that policy:

1. **Read the task.** What external service does it need? What data does it read or write?
2. **Check existing policies.** Call `policy_list`. Reuse if something fits.
3. **If nothing fits, either consult the wizard or draft directly.** If the policy shape is unfamiliar — new preset, taint concerns, trifecta risk — fork `wizard_v1` and ask it to draft. If you know the shape, draft directly.
4. **Propose.** Call `policy_propose` with the drafted `MediationPolicy`. The mediator subset-checks against the sandbox ceiling (auto-deny if paths are outside), then the operator approves on Telegram.
5. **Fork.** `fork_with_policy` creates the child workflow. Your policy's `allowed_child_policies` must admit the target (fnmatch); otherwise auto-deny.
6. **Wait + read.** Poll `mediator_ps` until the child exits, then read its output from `/sandbox/.mediator/policies/<policy_name>/workspace/`.

## The 7 syscalls

### Discovery

**`policy_list`** — enumerate approved policies.

```json
{"method": "policy_list", "params": {}}
→ [{"policy_name": "web_fetcher_v1", "rationale": "Web content fetcher"}, ...]
```

**`policy_get`** — full config for one policy.

```json
{"method": "policy_get", "params": {"policy_name": "web_fetcher_v1"}}
→ {"policy_name": "web_fetcher_v1", "http_allowlist": [...], ...}
```

**`mediator_ps`** — list active workflows. Poll this while waiting for a child to finish. When the child's `workflow_id` is gone, it exited.

```json
{"method": "mediator_ps", "params": {}}
→ [{"workflow_id": "fetch_1", "policy_name": "web_fetcher_v1", "uid": 100042}]
```

### Policy lifecycle

**`policy_propose`** — request a new approved policy. Subset-checked against the sandbox ceiling first. Then forwarded to the operator via the policy channel for approval.

```json
{
  "method": "policy_propose",
  "params": {
    "config": {
      "policy_name": "web_fetcher_v1",
      "rationale": "Fetch data via Brave search API",
      "http_allowlist": [
        "https://api.search.brave.com/*",
        "http://host.docker.internal:4000/*"
      ],
      "external_mounts": [],
      "allowed_child_policies": [],
      "bind_ports": null,
      "allowed_ipc_targets": [],
      "allowed_signal_targets": [],
      "allowed_launch_commands": ["openclaw agent --local *"]
    }
  }
}
```

**`revoke_policy`** — remove an approved policy. Init-only in most deployments.

### Process

**`fork_with_policy`** — spawn a child workflow under an approved policy. Returns immediately with the child's UID + GID + `workflow_token`.

```json
{
  "method": "fork_with_policy",
  "params": {
    "workflow_id": "fetch_1",
    "policy_name": "web_fetcher_v1",
    "command": [
      "openclaw", "agent", "--local", "-m",
      "Fetch nutrition for apples per 100g. Write to /sandbox/.mediator/policies/web_fetcher_v1/workspace/fetch_1.json."
    ]
  }
}
→ {"uid": 100042, "gid": 70003, "workflow_token": "hex...", "inherited_from": null}
```

The `inherited_from` field in the response is always `null` in the simplified mediator — retained for wire compat only.

**Gates on `fork_with_policy`:**
- Target `policy_name` must already be approved (appears in `policy_list`).
- Your own policy's `allowed_child_policies` must include (exact or fnmatch glob match) the target name. Otherwise: `policy 'X' is not in caller's allowed_child_policies (patterns=[...])`.
- Target's `allowed_launch_commands`, if non-empty, must admit the `command` you pass.

**`signal`** — send `term`/`kill`/`stop`/`cont` to a workflow. Gated by your policy's `allowed_signal_targets` (which policy names you can signal, and which signal types).

## Policy shape (`MediationPolicy`)

```yaml
policy_name: "<descriptive_name_v<N>>"  # globally unique, versioned
rationale: "<1-sentence purpose for operator review>"

http_allowlist:
  - "<fnmatch glob URL>"

external_mounts:
  - path: "<absolute path under sandbox ceiling>"
    mode: "<r | rw | rx | rwx>"

# fnmatch glob patterns matched against target policy names at fork time
allowed_child_policies:
  - "wizard_v1"           # explicit name
  - "fetcher_v*"          # glob for version family
  # [] = this policy's workflows may not fork children

bind_ports: null  # usually null; set only if the workflow actually listens

allowed_ipc_targets: []  # always empty; IPC was removed

allowed_signal_targets:
  - policy_name: "<fnmatch>"
    signals: ["term", "kill"]

allowed_launch_commands:
  - "<fnmatch glob>"  # must match the command passed to fork_with_policy
```

## The subset rule

Every proposed policy is a strict subset of the sandbox's ceiling. Specifically:

- **Filesystem** (checked at propose time): every `external_mount.path` must be a subpath of some entry in the sandbox's `FilesystemPolicy.read_only ∪ read_write`. Component-wise prefix (so `/workspace/fetcher` ⊆ `/workspace` but `/workspace-other` is NOT). Failing the subset check returns `subset_check_failed: <detail>` — no bridge call, no operator involvement.
- **Network** (enforced at runtime by the L7 proxy): each URL your child tries to reach is checked against your policy's `http_allowlist` + the sandbox's underlying `NetworkPolicy`. Out-of-ceiling hosts get CONNECT-denied at runtime. Your proposal isn't blocked at propose time for network, but the child's traffic won't flow.
- **Mount changes require sandbox restart.** You cannot propose a policy that adds a new hostPath mount not already in the sandbox ceiling. Ask the operator to expand the sandbox (which they do via the OpenShell draft flow), then re-propose.

## The policy wizard

When you're not sure how to draft — new endpoint, shaping concerns, trifecta risk — fork `wizard_v1`:

```json
{
  "method": "fork_with_policy",
  "params": {
    "workflow_id": "wizard_consult_<N>",
    "policy_name": "wizard_v1",
    "command": [
      "openclaw", "agent", "--local", "-m",
      "<your context + request>"
    ]
  }
}
```

The wizard reads sandbox state (preset YAMLs, approved policies), reasons via LiteLLM, and writes a drafted `MediationPolicy` YAML in its stdout log. You read it from `/sandbox/.mediator/workflows/wizard_consult_<N>/stdout.log`. The wizard's output has a `## Policy` fenced YAML block you can extract and submit via `policy_propose`.

The wizard's own policy:
- HTTP: LiteLLM only.
- Filesystem: read-only on the sandbox baseline; write to its own workspace.
- No binds, no signals, no children.
- Stateless across invocations — each fork is a fresh agent process.

To fork the wizard, your own policy must include `"wizard_v1"` (or a glob that matches) in `allowed_child_policies`.

## The trifecta rule

A single policy must NOT have all three of:

1. **`pii` sensitive data access** (reads or writes)
2. **`untrusted` inputs** (content from outside the trust boundary — web pages, user messages, etc.)
3. **`external` egress** (HTTP to endpoints not otherwise trusted for this data type)

The mediator's taint analyzer flags trifecta combinations at `policy_propose` time and surfaces them to the operator on the policy channel. The operator may approve anyway (if the task genuinely requires it), or ask the wizard to redraft.

Typical trifecta decomposition:

| Policy | Legs | Role |
|---|---|---|
| `fetcher_v1` | untrusted + external | Fetches raw content from untrusted web sources |
| `processor_v1` | untrusted + pii | Reads fetcher's output, sanitizes, writes to pii-accessible path |
| `egress_v1` | trusted + pii + external | Reads clean output, posts to trusted external system |

Each is 2-legged. No single workflow holds the 3.

## Coordinating between workflows

IPC was removed. Coordination happens via the shared policy workspace:

- Each approved policy has `/sandbox/.mediator/policies/<policy_name>/workspace/` accessible by that policy's GID.
- Children write output to a path their task instructions specify (include the full path in the `command` you send on fork).
- The caller polls `mediator_ps`; when the child's `workflow_id` disappears, it exited.
- Caller reads the output file from the workspace.

For multi-stage pipelines (fetcher → processor), use two separate policy workspaces; the processor's policy grants read access to the fetcher's workspace via `external_mounts`.

## Failure modes

| Error | Meaning | Action |
|---|---|---|
| `subset_check_failed: external_mount '<path>' is not a subpath of ...` | Your proposed path is outside the sandbox's filesystem ceiling | Narrow the path, or ask the operator to expand the sandbox |
| `policy 'X' is not in caller's allowed_child_policies (patterns=[...])` | Your own policy doesn't admit forking that target | Propose widening your own policy; operator approves |
| `policy_propose` returns denied with reason | Operator rejected | Read the reason, revise the proposal (or consult wizard) |
| Approval times out | Operator didn't respond within bridge timeout | Retry later; the policy is NOT pre-approved |
| Child exits without writing expected file | Crashed early | Read `/sandbox/.mediator/workflows/<workflow_id>/stderr.log` |
| `fork_with_policy` succeeds but child traffic blocked at runtime | Child's URL not in sandbox's L7 allowlist | Propose widening either your child's policy or the sandbox ceiling |

## Honesty

Every syscall is audit-logged. The operator can (and does) verify claims against the log and iptables counters. If `mediator_ps` shows a child exited in 0.2 seconds with 0 bytes through the proxy, that child did nothing — don't report its "results". If a child's `stderr.log` shows an error, report the error verbatim. Do not fabricate success.

The wizard is a thinking aid, not a substitute for grounding. Read before drafting. Read before reporting. Never invent.
