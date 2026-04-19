---
name: mediator
description: "OpenShell mediator syscalls — propose subset policies, fork child workflows, consult the policy wizard. Use when: the user asks for a capability you don't currently have (web fetch, network access, sensitive file read), OR when you'd otherwise have to refuse a request because a tool isn't configured. The mediator lets you spawn a child workflow with a custom policy (subset of the sandbox) instead of giving up. NOT for: built-in tool calls that already work, or for tasks you can complete with existing skills."
metadata: { "openclaw": { "emoji": "🛡️", "always": true } }
---

# Mediator Skill — Native Tools for Capability Acquisition

You have mediator syscalls as **native tools** in your tool list. Call them directly — they work exactly like `web_search` or `read`. Do NOT use `exec` or shell commands to reach the mediator.

## Core mental model

- Every policy you propose must be a **strict subset of the sandbox's ceiling**. The mediator auto-denies at propose time if you reach for anything the sandbox doesn't have (paths outside the filesystem allowlist, for now — network subset is runtime-enforced via the L7 proxy).
- Inheritance is GONE. Every proposed policy subset-checks against the live sandbox policy directly, never against a parent's runtime policy. No `inherit:` field anywhere.
- Before you can fork a policy, your OWN policy's `allowed_child_policies` list must include (via exact name or fnmatch glob) the target policy's name. Otherwise the fork auto-denies.
- Capability expansion goes: YOU propose → operator sees via Telegram **policy channel** → operator approves (or consults the wizard for help drafting something better) → mediator admits the policy → you fork into it.

## Your native tools

| Tool | Purpose |
|---|---|
| `policy_propose` | Submit a MediationPolicy for operator approval. Returns when approved or denied. |
| `fork_with_policy` | Spawn a child workflow under an approved policy. Child gets its own UID, GID, bound iptables + proxy rules. |
| `policy_list` | Enumerate approved policies visible to you. Call this before proposing to avoid duplicates. |
| `policy_get` | Fetch the full config for one approved policy. Useful to understand shape before proposing similar. |
| `mediator_ps` | List active workflows + their policies. Useful for debugging and trifecta awareness. |
| `signal_workflow` | Send `term`/`kill`/`stop`/`cont` to a workflow. Rarely used; gated by caller policy's `allowed_signal_targets`. |
| `revoke_policy` | Destroy an approved policy. Rarely used; init-only in most deployments. |

No `ipc_send`, no `ipc_connect` — they were dropped. Coordination between workflows happens via the shared policy workspace (see below).

## The Policy Wizard

If you're not sure how to compose a proposal — unfamiliar endpoint, unclear shape, trifecta concerns — **consult the wizard**. Fork a workflow under `wizard_v1`:

```json
{
  "workflow_id": "wizard_consult_1",
  "policy_name": "wizard_v1",
  "command": ["openclaw", "agent", "--local", "-m", "<your context + question>"]
}
```

The wizard has read access to the sandbox's policies, preset YAMLs at `/opt/nemoclaw-blueprint/policies/presets/`, and LLM reasoning. It responds with a drafted MediationPolicy in `## Policy` fenced YAML + rationale + taint analysis. You read its output from `/sandbox/.mediator/workflows/wizard_consult_<N>/stdout.log`, then submit the draft via `policy_propose`.

Your policy must include `"wizard_v1"` (or a glob that matches it) in `allowed_child_policies` for this fork to succeed. If it doesn't, ask the operator to widen your policy first.

## Message passing between workflows

IPC was removed. Use the filesystem:

Each policy has a shared workspace at `/sandbox/.mediator/policies/<policy_name>/workspace/` — children of that policy write there (owned by the per-policy GID), and you (as caller) can read it.

Pattern:
1. Propose the child policy with a write-accessible workspace (default behavior).
2. Tell the child (via the `command` argument to `fork_with_policy`) the exact output path it should write to.
3. Poll `mediator_ps` — when the child's `workflow_id` disappears, it exited.
4. Read the output file from its policy workspace.

## The Trifecta Rule

A single policy must NOT have all three of: **(1) sensitive data access** + **(2) untrusted input** + **(3) external egress**. When a task involves all three, **decompose**:

1. **Fetcher** — external + untrusted, no sensitive. Writes raw data.
2. **Processor** — untrusted + sensitive, no external. Reads fetcher's output, writes clean result.
3. **Egress** (if needed) — sensitive + external + trusted, no untrusted source. Reads clean result, posts out.

Each policy has at most 2 legs. No single workflow holds the dangerous 3.

The mediator's taint analyzer flags trifecta at `policy_propose` time. The operator sees the warning on Telegram and may approve anyway (if they understand the risk) or ask the wizard to redraft.

## Worked example: "look up calorie counts"

### Step 1 — check existing policies

Call `policy_list`. If a fetcher policy already exists, skip to step 4.

### Step 2 — (optional) consult the wizard

If unsure about the shape, fork `wizard_v1` with your context:

```json
{
  "workflow_id": "wizard_consult_1",
  "policy_name": "wizard_v1",
  "command": [
    "openclaw", "agent", "--local", "-m",
    "User wants nutrition data for blueberries from a reputable source. Draft a MediationPolicy that fetches from api.search.brave.com. Show rationale + taint analysis + full YAML."
  ]
}
```

Poll `mediator_ps` until the wizard exits, then read its `stdout.log`. The wizard's `## Policy` YAML block is your proposal draft.

### Step 3 — propose the policy

```json
{
  "config": {
    "policy_name": "web_fetcher_v1",
    "rationale": "Fetch data via Brave search API; reasoning via LiteLLM.",
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
```

Telegram pings the operator. Wait for approval.

### Step 4 — fork the fetcher

```json
{
  "workflow_id": "nutrition_1",
  "policy_name": "web_fetcher_v1",
  "command": [
    "openclaw", "agent", "--local", "-m",
    "Search for nutrition info for blueberries per 100g. Write your findings to /sandbox/.mediator/policies/web_fetcher_v1/workspace/nutrition_1.json as JSON with fields: calories, protein_g, carbs_g, fat_g, fiber_g, source_url."
  ]
}
```

For your own policy to admit this fork, `allowed_child_policies` must include `web_fetcher_v1` (exact or glob like `web_*_v*`). The fork auto-denies otherwise; if it happens, widen your own policy via a wizard-assisted proposal.

### Step 5 — wait and read

Poll `mediator_ps` until `nutrition_1` is gone. Then `read /sandbox/.mediator/policies/web_fetcher_v1/workspace/nutrition_1.json` and report verbatim. If the file is empty or malformed, check `/sandbox/.mediator/workflows/nutrition_1/stderr.log` — do NOT fabricate results.

## Key rules

- **Always propose full subsets.** Paths outside the sandbox's filesystem ceiling are auto-denied at propose time with `subset_check_failed: ...`.
- **Use `openclaw agent --local *` as the launch command** for policies whose children should run OpenClaw sessions. Other common launch commands: `"python3 /sandbox/<script>.py *"` for deterministic scripts, `"curl *"` for minimal HTTP tools.
- **Include the LiteLLM endpoint** `http://host.docker.internal:4000/*` in `http_allowlist` for any policy whose children run `openclaw agent`. The agent calls LiteLLM on every reasoning step; without it, every turn fails with "LLM request failed".
- **`allowed_child_policies`** is a list of fnmatch glob patterns matched against target policy names at fork time. `["*"]` admits any, `["web_fetcher_v*"]` admits the version family, `[]` forbids all forks.
- **`inherit` is gone.** Do not pass it in `fork_with_policy` params.
- **Reuse policies.** Multiple workflows under the same approved policy are fine.

## Failure modes

- **`subset_check_failed: ...`** — you proposed paths outside the sandbox's filesystem ceiling. Narrow and retry, or ask the operator to widen the sandbox.
- **`policy '<name>' is not in caller's allowed_child_policies`** — your own policy doesn't admit forking into that target. Either propose a widening of your own policy (operator approves), or (if this is hot-path) fork the wizard first and ask it to draft something.
- **`policy_propose` denied by operator** — operator typed deny (optionally with a reason). Revise and resubmit, or ask the wizard to help.
- **Approval times out** — operator didn't respond within the bridge timeout. Try later; the mediator didn't pre-approve.
- **Result file missing after child exits** — child crashed before writing. Check `/sandbox/.mediator/workflows/<workflow_id>/stderr.log`.

## Honesty

Every syscall is audit-logged. Fork events land on the operator's **runtime channel** (second Telegram bot), so they can see activity without being interrupted for approval. If a call fails, report the real error verbatim — do not fabricate results, do not pretend a child succeeded when it didn't.
