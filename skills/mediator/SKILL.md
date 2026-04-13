---
name: mediator
description: "OpenShell mediator syscalls — propose policies, fork child workflows, IPC between agents. Use when: the user asks for a capability you don't currently have (web fetch, network access, sensitive file read, talking to other agents), OR when you'd otherwise have to refuse a request because a tool isn't configured (e.g. 'Brave API key not set', 'web search unavailable', 'I can't access the internet'). The mediator lets you spawn a child workflow with a custom policy instead of giving up. NOT for: built-in tool calls that already work, or for tasks you can complete with existing skills."
metadata: { "openclaw": { "emoji": "🛡️", "always": true } }
---

# Mediator Skill — Native Tools for Capability Acquisition

You have mediator syscalls as **native tools** in your tool list. Call them directly — they work exactly like `web_search` or `read`. Do NOT use `exec`, `/sandbox/mediator-cli`, or shell commands.

## When to Use

- User wants live web data and you don't have web search → `policy_propose` a child with HTTP access
- User wants you to talk to a service you can't reach → propose a policy for it
- User wants sensitive files not in your mounts → propose a reader policy
- You need to coordinate with another workflow → `ipc_send` / `ipc_connect`
- Any "I can't do X" → propose X instead of refusing

## When NOT to Use

- Tool that already works (just call it)
- Task another loaded skill handles
- Request you'd refuse on safety grounds (forking doesn't bypass that)

## Your Native Tools

| Tool | What it does |
|---|---|
| `policy_propose` | Request a new child policy (operator must approve via Telegram) |
| `fork_with_policy` | Spawn a child workflow under an approved policy |
| `ipc_send` | Send a message to another workflow |
| `ipc_connect` | Open a bidirectional stream |
| `policy_list` | List all approved policies |
| `policy_get` | Inspect a specific policy |
| `mediator_ps` | List visible workflows |
| `signal_workflow` | Send term/kill/stop/cont to a workflow |
| `request_port` | Allocate a port |
| `revoke_policy` | Destroy a policy |

## Worked Example: "look up calorie counts"

1. **Check existing policies:** call `policy_list` — if a fetcher policy exists, skip to step 3
2. **Propose:** call `policy_propose` with:
   ```json
   {
     "config": {
       "policy_name": "nutrition_fetcher_v1",
       "rationale": "Live calorie lookup for user meal plan",
       "http_allowlist": ["https://api.search.brave.com/*", "https://api.nal.usda.gov/*"],
       "external_mounts": [],
       "allowed_child_policies": [],
       "bind_ports": null,
       "allowed_ipc_targets": ["init"],
       "allowed_signal_targets": []
     }
   }
   ```
   Wait for operator approval (Telegram bridge). If denied, revise the rationale or scope.
3. **Fork:** call `fork_with_policy` with `workflow_id`, `policy_name`, `inherit: false`
4. **Send task:** call `ipc_send` with the child's workflow_id and your request
5. **Read results** from the IPC response

## The Trifecta Rule

A single policy must NOT have all three of: **(1) sensitive data mount + (2) untrusted input + (3) external network egress**. Split into a chain:

- **Reader** mounts sensitive data, IPCs to processor only
- **Processor** receives from reader, IPCs to sender (with scrubber)
- **Sender** receives from processor, has external HTTP egress

## Failure Modes

- **`policy_propose` denied** → operator rejected. Revise rationale or narrow scope.
- **`fork_with_policy` EPERM** → your policy doesn't allow that child. Check with `policy_get`.
- **`ipc_send` fails** → child not running. Check with `mediator_ps`.
- **Approval times out (5min)** → operator didn't respond. Try again later.

## Honesty

Every syscall is audit-logged. The operator can verify everything. If a call fails, report the real error. Do not fabricate results.
