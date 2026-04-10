---
name: mediator
description: "OpenShell mediator syscalls — propose policies, fork child workflows, IPC between agents. Use when: the user asks for a capability you don't currently have (web fetch, network access, sensitive file read, talking to other agents), OR when you'd otherwise have to refuse a request because a tool isn't configured (e.g. 'Brave API key not set', 'web search unavailable', 'I can't access the internet'). The mediator lets you spawn a child workflow with a custom policy instead of giving up. NOT for: built-in tool calls that already work, or for tasks you can complete with existing skills."
metadata: { "openclaw": { "emoji": "🛡️", "always": true } }
---

# Mediator Skill — Real Capabilities via Policy Proposal

You run inside an OpenShell sandbox under a mediated policy. Most "capabilities" you'd reach for as built-in tools — web fetch, sockets, sensitive mounts, talking to other agents — are gated by policy, not absent. When a tool says "not configured" or you'd refuse for lack of access, **your first move is to propose a child workflow with the right policy and fork it**, not to give up.

The full reference is at `/sandbox/.openclaw/workspace/MEDIATOR.md`. Read it once, then keep this skill loaded as the trigger.

## When to Use

- ✅ User wants live web data (calorie counts, news, prices, search) and you don't have web search
- ✅ User wants you to talk to a service you can't currently reach
- ✅ User wants you to read sensitive files that aren't in your mounts
- ✅ You need to coordinate with another running workflow
- ✅ Any "I'd love to help but I don't have X" — propose X instead of refusing

## When NOT to Use

- ❌ Tool that already works (just call it)
- ❌ Task another loaded skill handles
- ❌ Request you'd refuse on policy/safety grounds (forking doesn't bypass that)

## The Trifecta Rule

A single policy must NOT have all three of: **(1) sensitive data mount + (2) untrusted input + (3) external network egress**. Split into a chain:

- **Reader** mounts sensitive data, IPCs to processor only
- **Processor** receives from reader, IPCs to sender (with scrubber)
- **Sender** receives from processor, has external HTTP egress

Each link has at most two of the three legs. The chain is safe; a monolith is not. The mediator runs taint analysis at `policy_propose` time and rejects (or warns about) trifecta violations.

## CLI Surface

The CLI lives at `/sandbox/mediator-cli`. **It takes JSON params, not flags.** Every method takes one JSON-object argument (or no argument for `ps` / `policy_list` / `request_port`).

In interactive shells, `MEDIATOR_SOCKET` and `MEDIATOR_TOKEN` are pre-exported by the sandbox bashrc, so `mediator-cli` just works. If you're running from a non-interactive subprocess and the env vars aren't set, fall back to:

```bash
export MEDIATOR_SOCKET=/sandbox/.mediator/mediator.sock
export MEDIATOR_TOKEN=$(cat /sandbox/.mediator/mediator.sock.token)
```

Output contract: success → JSON result on stdout, exit 0. Error → diagnostic on stderr, exit 1. **Always check exit code and quote actual stdout in your reports** — narrating what you "would have seen" is how confabulation starts.

## The 10 Methods

| Method | Mutating? | Params |
|---|---|---|
| `ps` | no | none |
| `policy_list` | no | none |
| `policy_get` | no | `{"policy_name": "..."}` |
| `policy_propose` | yes (operator approval) | `{"config": <full MediationPolicy>}` |
| `revoke_policy` | yes | `{"policy_name": "...", "hard": true}` |
| `fork_with_policy` | yes | `{"workflow_id": "...", "policy_name": "...", "inherit": true}` |
| `ipc_send` | yes | `{"target_workflow_id": "...", "message": {...}}` |
| `ipc_connect` | yes | `{"target_workflow_id": "..."}` |
| `signal` | yes | `{"target_workflow_id": "...", "signal": "term"}` |
| `request_port` | yes | none |

A `MediationPolicy` is the full object — every field must be present (even if empty). Fields:

```json
{
  "policy_name": "fetcher_v1",
  "rationale": "Web fetcher for nutrition data",
  "http_allowlist": ["https://api.search.brave.com/*"],
  "external_mounts": [],
  "allowed_child_policies": [],
  "bind_ports": null,
  "allowed_ipc_targets": ["init"],
  "allowed_signal_targets": []
}
```

`policy_propose` will reject configs with empty `policy_name`, missing required fields, or duplicate names.

## Discover

```bash
mediator-cli ps                                          # workflows you can see
mediator-cli policy_list                                 # policies you can fork
mediator-cli policy_get '{"policy_name": "init_v0"}'     # inspect one
```

## Propose

```bash
mediator-cli policy_propose '{
  "config": {
    "policy_name": "nutrition_fetcher_v1",
    "rationale": "User asked for live calorie data; child needs Brave Search egress.",
    "http_allowlist": ["https://api.search.brave.com/*"],
    "external_mounts": [],
    "allowed_child_policies": [],
    "bind_ports": null,
    "allowed_ipc_targets": ["init"],
    "allowed_signal_targets": []
  }
}'
```

When the approval bridge is configured, this round-trips through Telegram and blocks until the operator approves or denies (5-minute timeout). Returns `{"approved": true, "reason": "..."}` on approval, exits 1 with the denial reason otherwise.

## Fork

```bash
mediator-cli fork_with_policy '{
  "workflow_id": "nutrition_fetch_1",
  "policy_name": "nutrition_fetcher_v1",
  "inherit": false
}'
```

Returns `{"workflow_id": "...", "workflow_token": "...", "uid": ...}`. The child runs as its own UID with its own token. It can hit Brave Search but can't see your private context.

## IPC

```bash
# Fire-and-forget message
mediator-cli ipc_send '{
  "target_workflow_id": "nutrition_fetch_1",
  "message": {"action": "fetch", "url": "https://api.search.brave.com/res/v1/web/search?q=chicken+thigh+calories"}
}'

# Bidirectional stream (for back-and-forth conversation)
mediator-cli ipc_connect '{"target_workflow_id": "nutrition_fetch_1"}'
```

## Worked Example: "look up calorie counts"

```bash
# 1. Check if a fetcher policy already exists.
mediator-cli policy_list | grep -i fetcher

# 2. If not, propose one. (Wait for operator approval via Telegram.)
mediator-cli policy_propose '{
  "config": {
    "policy_name": "nutrition_fetcher_v1",
    "rationale": "Live calorie lookup for the user meal plan",
    "http_allowlist": ["https://api.search.brave.com/*", "https://api.nal.usda.gov/*"],
    "external_mounts": [],
    "allowed_child_policies": [],
    "bind_ports": null,
    "allowed_ipc_targets": ["init"],
    "allowed_signal_targets": []
  }
}' || { echo "Proposal denied or timed out — tell the user and stop"; exit 1; }

# 3. Fork the child.
mediator-cli fork_with_policy '{
  "workflow_id": "nutrition_fetch_1",
  "policy_name": "nutrition_fetcher_v1",
  "inherit": false
}'

# 4. Send it the fetch request.
mediator-cli ipc_send '{
  "target_workflow_id": "nutrition_fetch_1",
  "message": {"action": "fetch", "url": "https://api.search.brave.com/res/v1/web/search?q=chicken+thigh+calories"}
}'

# 5. Read the response (poll ipc or open ipc_connect for stream), summarize for the user.
```

## Failure Modes

- **Connection refused / `Error: cannot connect to mediator at ...`** → daemon isn't running. Check `/sandbox/.mediator/mediator.sock` exists; check `/sandbox/.mediator/daemon.log`. Don't fabricate results.
- **`Error: MEDIATOR_TOKEN not set`** → env vars aren't exported. Run the manual export above.
- **`policy_propose denied: no approval bridge configured`** → operator hasn't wired the bridge. Tell the user; this is a deployment issue, not something you can route around.
- **`policy denied: <reason>`** → operator rejected via Telegram. The reason is in the error. Either revise the proposal (smaller scope, different rationale) or tell the user.
- **`policy proposal timed out`** → operator didn't respond within 5 minutes. Try again later.
- **Fork fails with EPERM** → your parent policy doesn't list this child in `allowed_child_policies`. `policy_get` your own policy and check.
- **`Error [E0609]: trifecta violation`** at propose time → your policy combined all three legs. Split into a chain.
- **IPC times out** → child crashed or wasn't listening. `mediator-cli ps` to check; `signal` to kill if needed.

## Reporting Honestly

When you run mediator syscalls in service of a user request, your final report MUST include the literal stdout of every `mediator-cli` invocation. Do not summarize what you "would have seen" — paste the actual output. If a call failed, paste the actual error. If you can't run a call, say so plainly. The operator can verify everything against the audit log; fabricated narratives will be caught and undermine trust.

## Don't Refuse — Propose

The most important behavior: **when you'd otherwise say "I can't do X because Y isn't configured," propose a policy that grants Y instead**. The mediator exists so the agent doesn't have to be locked into its initial capability set.
