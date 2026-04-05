# Mediator Design Decisions

Architectural decisions from the design conversation (April 2026) that inform
the implementation of the 9-syscall mediator in OpenShell.

## Core Principle

> The entity being controlled must never be the entity evaluating the control.

The agent reasons and requests. The sandbox evaluates and mediates. The operator
approves and configures. Three roles, three privilege levels.

## Isolation Model: Per-Workflow UID Separation

Each workflow gets a unique Linux UID. All workflows share a single network
stack. Isolation is enforced by:

- **UID ownership** — per-workflow directories (mode 700), files inaccessible across UIDs
- **Landlock** — per-process filesystem restrictions applied in pre_exec
- **iptables `-m owner --uid-owner`** — per-UID network rules, only allow proxy
- **seccomp** — static syscall filter blocking dangerous + IPC syscalls
- **`hidepid=2` on /proc** — processes can only see their own UID's entries
- **SO_PEERCRED** — proxy and mediator identify callers by kernel-verified UID

### Why UIDs instead of namespaces

Namespaces (CLONE_NEWPID | CLONE_NEWNET | CLONE_NEWNS) provide stronger
isolation but introduce networking complexity:

- Each namespace needs its own veth pair with unique IP
- The L7 proxy must bind to each namespace's veth separately
- Inbound traffic requires DNAT rules per namespace
- Heavyweight: ~100-200ms per clone() + veth + iptables setup

UID separation provides equivalent practical isolation at much lower cost:

- One shared network stack, one proxy, one listener
- Proxy identifies workflows via SO_PEERCRED UID lookup (fast)
- Inbound traffic routes to the process that bound the port (standard TCP)
- Lightweight: just allocate a UID and set iptables rules

The tradeoff: a local privilege escalation to root breaks UID isolation.
This is mitigated by seccomp blocking all escalation paths (setuid, ptrace,
unshare, etc.) and the sandbox holding CAP_SYS_ADMIN, not the agent.

## Mediator as Embedded Control Plane

The mediator runs **inside** the sandbox process (not as a separate daemon).
This gives it:

- Shared memory access to the OPA engine for hot-reloading per-workflow policies
- Direct UID→policy registry via `Arc<RwLock<HashMap<u32, EffectivePolicy>>>`
- Zero I/O overhead for policy lookups

```
fork_with_policy("wf_child", "scraper_v1", inherit=false)
  │
  ▼ Mediator (control plane)
  │
  ├─ Allocate UID from pool (e.g., 60000-65534)
  ├─ Create per-UID directory: /run/openshell/workflows/{uid}/ (mode 700)
  ├─ Set up external mounts via POSIX ACLs (setfacl -m u:{uid}:rwx /path)
  ├─ iptables: -m owner --uid-owner {uid} rules (ACCEPT proxy, REJECT else)
  ├─ Register UID → effective_policy in proxy lookup table
  ├─ Push per-UID network policy to OPA engine
  ├─ Landlock: build FilesystemPolicy from external_mounts
  ├─ fork() → pre_exec(setuid + drop_privs + landlock + seccomp) → exec()
  │
  ▼ Return { pid, uid, workflow_token }
```

At runtime, enforcement is passive — the mediator is NOT in the hot path:

- HTTP traffic: agent → proxy (127.0.0.1:3128) → SO_PEERCRED → UID → policy → OPA → internet
- Filesystem: agent → Landlock (kernel-enforced per-process) → disk
- Port binding: iptables per-UID rules control which ports accept inbound

## The Nine Syscalls

```
1. http_request(requests[], workflow_token) → Response[] | ENETDENIED
2. policy_propose(config) → { approved: bool } | ENOPRIV
3. fork_with_policy(workflow_id, policy_name, inherit) → { pid, uid, workflow_token, inherited_from } | EPERM
4. request_port(workflow_token) → { port } | ENOSPC | EPERM
5. ipc_send(target_workflow_id, message, workflow_token) → { ack } | EPERM
6. ipc_connect(target_workflow_id, workflow_token) → { stream_handle } | EPERM
7. ps(workflow_token) → [{ workflow_id, policy_name }] | EPERM
8. signal(target_workflow_id, signal, workflow_token) → { ack } | EPERM
9. revoke_policy(policy_name, workflow_token) → { ack, affected } | EPERM
```

## Privilege Inheritance Model

### Departure from Linux

In Linux, capability monotonicity is a hard rule: children can only drop
privileges, never gain them through fork alone.

In this system, children can have capabilities that are a **superset of, subset
of, or entirely disjoint from** the parent's. This is a deliberate design choice.

The security guarantee shifts from kernel monotonicity to the **human approval
gate**. Every child policy was vetted by the operator when the parent's policy
was approved. The agent cannot invent new policies at runtime.

### The inherit flag

Defined per-child-policy in the parent's `allowed_child_policies`:

```yaml
allowed_child_policies:
  - policy_name: "quick_bash_task"
    inherit: true         # child gets union of parent + own policy
  - policy_name: "research_*"
    inherit: false        # child is independently scoped
  - policy_name: "*_helper"
    inherit: true         # helpers extend parent's capabilities
```

#### inherit: false (independent)

- New UID allocated
- New workflow token with `inherited_from: null`
- Syscalls evaluated against child's own policy ONLY
- Parent's http_allowlist, mounts, IPC targets do NOT carry over
- Child could have access to APIs the parent has never seen

#### inherit: true (extension)

- New UID allocated
- New workflow token with `inherited_from: parent_token`
- Syscalls evaluated against UNION of child + parent policies
- If either policy allows the operation, it proceeds
- Audit log tracks which policy was used for each syscall

Both cases get a unique UID. The inherit flag only controls the **policy chain**,
never the isolation boundary. Even two helpers inheriting from the same parent
are fully isolated from each other via UID separation.

### Token lookup

```
workflow_token → {
  own_policy: "child_policy_name",
  inherited_from: "parent_token" | null,
  uid: 60042
}
```

### Eager merge with chain retention

At fork time, the mediator computes the **effective policy** (union of all
inherited policies) and pushes it to enforcers. But it retains the full chain
for revocation:

```
uid 60042 → {
  effective_policy: { merged http_allowlist, mounts, ports, etc },
  chain: [token_C, token_B, token_A],
  chain_policies: ["sub_v1", "helper_v1", "init_v0"]
}
```

Why eager: one OPA evaluation per request, no chain walking in the hot path.
Why retain chain: revocation needs to know which workflows are affected.

## Enforcer Integration

### How each layer identifies the process

| Layer | Identification | Timing |
|-------|---------------|--------|
| **Landlock** | `restrict_self()` inside the process | Fork time (pre_exec) |
| **Seccomp** | `prctl()` + BPF inside the process | Fork time (pre_exec) |
| **L7 proxy** | UID via SO_PEERCRED on TCP socket | Runtime (per request) |
| **iptables** | `-m owner --uid-owner {uid}` | Fork time (rule insertion) |

### MediationPolicy → enforcer mapping

| MediationPolicy field | Enforcer | Method |
|----------------------|----------|--------|
| `http_allowlist` | L7 proxy / OPA | Add to OPA data keyed by UID, hot-reload engine |
| `external_mounts` | Landlock + GID + ACLs | Landlock in pre_exec; setgid dirs + default ACLs |
| `bind_ports` | iptables | INPUT ACCEPT rule for port range, per-UID |
| (all) | seccomp | Static filter, same for all workflows |

### iptables rules per workflow

Three OUTPUT rules per UID. No blanket loopback ACCEPT — that would let
workflows connect to each other's listening ports on localhost.

```bash
# Outbound: only allow proxy + responses
iptables -A OUTPUT -m owner --uid-owner {uid} -d 127.0.0.1 -p tcp --dport 3128 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner {uid} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner {uid} -j REJECT

# Inbound: only allocated ports (added by request_port)
iptables -A INPUT -p tcp --dport {port} -j ACCEPT  # global, first-come-first-served
```

Why this works:

- **Proxy (port 3128)**: explicitly allowed. All HTTP goes through it.
- **Cross-workflow**: UID 60002 tries `connect(127.0.0.1:8080)` where UID
  60001 is listening → REJECT by rule 3. Packet never reaches 60001.
- **Responses**: proxy responds to UID 60002's allowed connection → matches
  ESTABLISHED (part of a connection 60002 initiated) → ACCEPT.
- **Mediator**: uses Unix domain socket, not TCP. iptables doesn't filter
  UDS traffic. Access controlled by filesystem permissions on socket file.
- **Inbound from gateway**: SSH tunnel delivers to `127.0.0.1:{port}` →
  INPUT chain, not OUTPUT. No per-UID INPUT blocking needed — the gateway
  already authenticated the connection via SSH.

### Proxy integration (SO_PEERCRED)

The proxy binds to `127.0.0.1:3128`. When a connection arrives:

1. `getsockopt(SO_PEERCRED)` → get caller's UID and PID
2. Lookup UID in `HashMap<u32, EffectivePolicy>` → get effective policy
3. OPA evaluates against that policy's network rules
4. Allow → connect upstream, relay with L7 inspection
5. Deny → 403 Forbidden

This eliminates the expensive `/proc/net/tcp` inode scanning that the current
proxy does. SO_PEERCRED is a single syscall, kernel-verified.

### Filesystem: Group-Based Ownership Model

File ownership by UID is **cosmetic**. All real access flows through GIDs
(policy groups) and POSIX ACLs. Each policy maps to a Linux group. Workflows
run with `umask 007` so files are always group-accessible.

#### Policy groups

Each approved policy gets a GID. All workflow UIDs running that policy are
members of the group:

```
Policy "research_v1" → gid 70001
  uid 60001 ∈ gid 70001
  uid 60002 ∈ gid 70001

Policy "analyzer_v1" → gid 70002
  uid 60003 ∈ gid 70002
```

#### Directory layout

All directories are group-owned. No private UID-owned dirs needed:

```
/data/research_v1/                       (root:70001, mode 2770, setgid)
  shared/                                ← memories, notes, shared knowledge
    context.md                           (60001:70001, mode 660)
    findings.md                          (60002:70001, mode 660)
  instances/
    wf_scraper_42/                       ← OpenClaw state for this instance
      .openclaw/session.db               (60001:70001, mode 660)
    wf_scraper_43/
      .openclaw/session.db               (60002:70001, mode 660)
```

The setgid bit ensures new files inherit the directory's group (70001).
With `umask 007`, files are created `{uid}:70001` with mode `rw-rw----`.
The UID owner field is irrelevant — all access goes through the group.

#### Cross-policy sharing

When multiple policies need access to the same directory, use default ACLs:

```bash
# Directory setup (once)
setfacl -m g:70001:rwx /data/knowledge_base      # research_v1 access
setfacl -m g:70002:rw- /data/knowledge_base       # analyzer_v1: read-write
setfacl -d -m g:70001:rwx /data/knowledge_base    # default ACL: new files
setfacl -d -m g:70002:rw- /data/knowledge_base    # default ACL: new files
```

New files inherit both ACLs. Each policy's access is independently revocable
via `setfacl -x`.

#### Why UIDs don't matter for files

- `umask 007`: owner and group always get the same permissions
- setgid directories: group inherited from directory, not process
- Dead UIDs: files remain group-accessible, no chown needed on teardown
- No expensive `find` for cleanup — group ownership is durable

#### Per-instance separation

Two instances of the same policy write to separate subdirectories
(`instances/wf_scraper_42/` vs `instances/wf_scraper_43/`) to avoid
SQLite lock contention and session state conflicts. But both are
group-readable — a future instance can read a dead instance's data.

#### On first fork of a new policy

```bash
# Create policy group
groupadd -g 70001 research_v1

# Create shared directory
mkdir -p /data/research_v1/shared /data/research_v1/instances
chown -R root:70001 /data/research_v1
chmod -R 2770 /data/research_v1

# Set up cross-policy ACLs if needed
setfacl -m g:70001:rwx /data/knowledge_base
setfacl -d -m g:70001:rwx /data/knowledge_base
```

#### On every fork_with_policy

```bash
# Add UID to policy group
usermod -aG research_v1 60042   # (or glibc call in Rust)

# Create instance directory
mkdir /data/research_v1/instances/wf_scraper_42
chown 60042:70001 /data/research_v1/instances/wf_scraper_42
chmod 2770 /data/research_v1/instances/wf_scraper_42
```

#### On revocation

```bash
# Remove policy group's ACL from cross-policy dirs
setfacl -x g:70001 /data/knowledge_base
setfacl -d -x g:70001 /data/knowledge_base
```

Shared files within the policy's own directory persist (group-owned).
Cross-policy access is removed. No file ownership changes needed.

### Seccomp hardening (additions for UID model)

Block SysV IPC (cross-UID communication bypass):
- `shmget`, `shmat`, `shmctl`, `shmdt`
- `msgget`, `msgsnd`, `msgrcv`, `msgctl`
- `semget`, `semop`, `semctl`

Block UID escape:
- `setuid`, `setgid`, `setgroups`, `setresuid`, `setresgid`

Already blocked:
- `ptrace`, `bpf`, `memfd_create`, `mount`, `io_uring_setup`, `process_vm_readv`
- `execveat` with `AT_EMPTY_PATH`, `unshare` with `CLONE_NEWUSER`

### Process visibility

Mount `/proc` with `hidepid=2`:
```bash
mount -o remount,hidepid=2 /proc
```

Processes can only see their own UID's entries. Prevents workflows from
discovering each other's PIDs, command lines, or environment variables.

## Identity Without Spoofing

Identity is derived from `SO_PEERCRED` — a Linux socket option that returns the
real PID/UID of the process on the other end of a Unix domain socket. The agent
can put whatever it wants in the JSON payload; the sandbox ignores it and checks
the socket credential.

The workflow token is additionally validated:
1. Agent sends workflow_token in request
2. Sandbox checks SO_PEERCRED for real UID and PID
3. Sandbox looks up token in database
4. Token must match the UID that was assigned at fork time
5. Policy is loaded from the token's policy_name + inheritance chain

## fork_with_policy: Detailed Flow

```
1.  Validate: does caller's policy allow forking this child policy?
2.  Validate: does inherit flag match the policy declaration?
3.  Allocate UID from pool (monotonic counter, never recycled)
4.  First fork of this policy? Create policy group (GID), shared dirs, ACLs
5.  Add UID to policy group
6.  Create instance directory: /data/{policy}/instances/{workflow_id}/
7.  Install per-UID iptables rules (outbound: proxy only; inbound: none yet)
8.  Compute effective policy (merge chain if inherit=true)
9.  Register UID → effective_policy in proxy's lookup table
10. Push network policy to OPA engine (hot-reload)
11. Build Landlock FilesystemPolicy from policy dirs + shared paths
12. Build seccomp filter (static + SysV IPC blocks)
13. fork() child process
14. pre_exec: setuid(uid), setgid(policy_gid), umask(007)
             → drop_privileges → landlock::apply → seccomp::apply
15. exec() agent binary
16. Generate HMAC workflow token for child
17. Insert token + workflow into SQLite store
18. Return { pid, uid, workflow_token, inherited_from }
```

## signal: UID-Wide Process Kill

```
signal("wf_child", "kill", workflow_token)
  │
  ├─ Validate: caller's allowed_signal_targets permits this
  ├─ Look up target workflow → get UID
  ├─ Kill all processes running as that UID (pkill -U {uid})
  ├─ Remove per-UID iptables rules
  ├─ Remove UID → policy from proxy lookup
  ├─ Remove OPA policy data for this UID
  ├─ Remove UID from policy group
  └─ Audit log
```

Instance directory and shared files persist (group-owned). No cleanup needed.
UID is never recycled (monotonic counter with 4 billion range).

## request_port: Simplified

No DNAT needed. All workflows share the host network stack. The workflow
binds directly. The global port table prevents collisions.

```
request_port(workflow_token)
  │
  ├─ Check policy has bind_ports range
  ├─ Allocate next available port from global pool
  ├─ Add iptables INPUT rule: ACCEPT tcp dport {port}
  └─ Return { port }
```

On teardown, the INPUT rule is removed and the port is released.

## Policy Revocation

`revoke_policy` removes a policy and propagates to all affected workflows.

```
revoke_policy("helper_v1")
  │
  ├─ Find all workflows with "helper_v1" in their policy chain
  │
  ├─ For each affected workflow (identified by UID):
  │   ├─ Hard revoke: kill all processes as that UID, tear down
  │   └─ Soft revoke: recompute effective policy without helper_v1
  │       → hot-reload OPA with narrower allowlist
  │       → requests to helper_v1-only endpoints start getting 403'd
  │
  └─ Audit log
```

### Telegram daemon integration

```
/policies              → list active policies with chain info
/revoke scraper_v1     → hard revoke, kill affected workflows
```

## Init Process

Init is the first process spawned by the sandbox. It is the agent's coordinator
with a unique behavioral constraint: **every side effect requires human approval
via Telegram**.

### Init's capabilities

- All 9 syscalls, every one human-gated
- Broad filesystem access (bash, python, node, git, ssh, common Unix utilities)
- Telegram channel (read/write) for operator communication
- Working directory (read/write) for persistent session state
- Workflow outbox directories (read) for child output

### Init's policy wildcards

```yaml
allowed_child_policies: [{ policy_name: "*", inherit: true }]
allowed_ipc_targets: ["*"]
allowed_signal_targets: [{ policy_name: "*", signals: ["term", "kill", "stop", "cont"] }]
```

## Three-Role Model

| Role | Identity | Can do | Cannot do |
|------|----------|--------|-----------|
| Agent workflows | UID 100000+ (monotonic), GID per policy (70000+) | Reason, request syscalls, access group files | Set own policy, access other groups' files |
| Sandbox (mediator) | jarvis-sandbox | Mediate syscalls, manage UIDs/GIDs, enforce policy | Read agent reasoning, modify operator config |
| Daemon (human proxy) | jarvis-daemon | Own Telegram bot, approve policies, write config | Be influenced by the agent |

## What Doesn't Need a Syscall

- **Pre-opened resources**: Telegram output channel, working directory, outboxes
- **Group-scoped resources**: binaries, scripts, vault files (provisioned via GID + ACLs at fork time)
- **Persistent memory**: shared within policy via setgid dirs, across policies via ACLs
- **Cron**: just a binary on disk with execute permission
- **Internal subprocess IPC**: processes with the same UID communicate freely

Only cross-boundary operations need syscalls: outbound HTTP, spawning isolated
workflows, requesting new capabilities, cross-UID messaging, sending signals.

Filesystem access is entirely transparent to the agent. OpenClaw reads and
writes files normally. The kernel enforces GID and ACL permissions. The agent
never knows whether a path is shared within its policy, shared across policies,
or instance-specific.

## What Changes vs Existing OpenShell Code

| Component | Current | With Mediator |
|-----------|---------|---------------|
| `netns.rs` (810 lines) | Creates veth pairs, namespaces | **Eliminated** — replaced by UID + iptables |
| `process.rs` pre_exec | setns + drop_privs + landlock + seccomp | setuid + drop_privs + landlock + seccomp (no setns) |
| `proxy.rs` identity | Source IP → /proc/net/tcp inode scan → PID | SO_PEERCRED → UID (single syscall, no scanning) |
| `seccomp.rs` | Blocks dangerous syscalls | + blocks SysV IPC + UID escape syscalls |
| OPA engine | One policy per sandbox | Per-UID policy data, hot-reloaded at fork time |
| Proxy binding | Veth host IP (10.200.0.1:3128) | Loopback (127.0.0.1:3128) |
| Inbound traffic | SSH tunnel via gateway | SSH tunnel via gateway (unchanged) + direct port binding |
