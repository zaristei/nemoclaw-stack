---
name: mediator
description: "OpenShell mediator syscalls — propose policies, fork child workflows. Use when: the user asks for a capability you don't currently have (web fetch, network access, sensitive file read), OR when you'd otherwise have to refuse a request because a tool isn't configured (e.g. 'web search unavailable', 'I can't access the internet'). The mediator lets you spawn a child workflow with a custom policy instead of giving up. NOT for: built-in tool calls that already work, or for tasks you can complete with existing skills."
metadata: { "openclaw": { "emoji": "🛡️", "always": true } }
---

# Mediator Skill — Native Tools for Capability Acquisition

You have mediator syscalls as **native tools** in your tool list. Call them directly — they work exactly like `web_search` or `read`. Do NOT use `exec`, `/sandbox/mediator-cli`, or shell commands.

## When to Use

- User wants live web data and you don't have web search → `policy_propose` a child with HTTP access
- User wants you to talk to a service you can't reach → propose a policy for it
- User wants sensitive files not in your mounts → propose a reader policy
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
| `policy_list` | List all approved policies |
| `policy_get` | Inspect a specific policy |
| `mediator_ps` | List visible workflows |
| `signal_workflow` | Send term/kill/stop/cont to a workflow |
| `request_port` | Allocate a port |
| `revoke_policy` | Destroy a policy |

**Note:** `ipc_send` and `ipc_connect` are not yet functional. Use file-based message passing instead (see below).

## Worked Example: "look up calorie counts"

1. **Check existing policies:** call `policy_list` — if a fetcher policy exists, skip to step 3
2. **Propose:** call `policy_propose` with:
   ```json
   {
     "config": {
       "policy_name": "nutrition_fetcher_v1",
       "rationale": "Live calorie lookup for user meal plan",
       "http_allowlist": ["https://api.search.brave.com/*", "http://host.docker.internal:4000/*"],
       "external_mounts": [],
       "allowed_child_policies": [],
       "bind_ports": null,
       "allowed_ipc_targets": [],
       "allowed_signal_targets": [],
       "allowed_launch_commands": ["/sandbox/agent-bootstrap.sh *"]
     }
   }
   ```
   The `http_allowlist` includes the inference endpoint (`host.docker.internal:4000`) so the child agent can call the LLM. The `allowed_launch_commands` restricts what `fork_with_policy` can run — **always use `/sandbox/agent-bootstrap.sh`**, never raw `openclaw agent`.
   Wait for operator approval (Telegram bridge). If denied, revise the rationale or scope.
3. **Fork:** call `fork_with_policy` with:
   ```json
   {
     "workflow_id": "nutrition_task_1",
     "policy_name": "nutrition_fetcher_v1",
     "inherit": true,
     "command": ["/sandbox/agent-bootstrap.sh", "Look up calorie info for blueberries. Write your findings to /sandbox/.mediator/results/nutrition_task_1.json as valid JSON."]
   }
   ```
   The bootstrap script sets up the child's OpenClaw config, proxy routing, and LLM credentials, then runs `openclaw agent --local` under the child's UID. **Always use `/sandbox/agent-bootstrap.sh` as the command** — it handles all the plumbing. Pass the full task description as the only argument.
4. **Read results:** The child writes its output to a shared file path. After the child exits (poll with `mediator_ps` until the workflow disappears), read the result file:
   - Use the `read` tool on `/sandbox/.mediator/results/<workflow_id>.json`
   - The result directory `/sandbox/.mediator/results/` is writable by all child UIDs

   **IMPORTANT:** Always instruct the child (in the task description) to write its output to `/sandbox/.mediator/results/<workflow_id>.json`. This is the message-passing mechanism. Without this instruction, the child's output is lost.

## Result Directory Convention

The directory `/sandbox/.mediator/results/` is the shared mailbox between parent and children:
- Parent creates it before forking (the mediator daemon does this automatically)
- Child writes its result as JSON to `/sandbox/.mediator/results/<workflow_id>.json`
- Parent reads the file after the child exits
- Each child uses its own `workflow_id` as the filename to avoid collisions

Include the output path in the task description you pass to the bootstrap script. The child agent will use its `write` tool to create the file.

## The Trifecta Rule

A single policy must NOT have all three of: **(1) sensitive data mount + (2) untrusted input + (3) external network egress**. Split into a chain when needed.

## Failure Modes

- **`policy_propose` denied** → operator rejected. Revise rationale or narrow scope.
- **`fork_with_policy` EPERM** → your policy doesn't allow that child. Check with `policy_get`.
- **Approval times out (5min)** → operator didn't respond. Try again later.

## Honesty

Every syscall is audit-logged. The operator can verify everything. If a call fails, report the real error. Do not fabricate results.
