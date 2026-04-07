# Agent Instructions

This repo orchestrates NemoClaw and OpenShell services for local development and deployment. Follow these instructions when contributing.

## Project Structure

| Path | Purpose |
|------|---------|
| `openshell/` | OpenShell submodule — do not edit directly, work in `~/repos/OpenShell` |
| `nemoclaw/` | NemoClaw submodule — do not edit directly, work in `~/repos/NemoClaw` |
| `services/litellm/` | LiteLLM proxy config and env |
| `services/approval-bridge/` | Python webhook-to-Telegram bridge (chunks + policy proposals) |
| `scripts/` | Build, config, secrets, and verification scripts |
| `tests/honeypot/` | Red team honeypot (fake PII, WhatsApp bridge, agent loop) |
| `tests/boot-prompts/` | Test system prompts for sandbox injection |
| `docs/` | Design docs, syscall guide, HTML writeup |
| `stack.sh` | Unified CLI: start, stop, ps, health, create, verify-models |

## Submodule Workflow

- Never commit changes inside `openshell/` or `nemoclaw/` directories directly.
- Make changes in the standalone repos (`~/repos/OpenShell`, `~/repos/NemoClaw`), push to fork, then update the submodule pointer here.
- To update a submodule: `cd <submodule> && git fetch fork && git checkout fork/<branch>`, then commit from the repo root.

## LiteLLM Config

- Edit source files in `services/litellm/config/` (models.yaml, litellm_config.yaml, trusted_providers.yaml).
- Never edit `litellm_config.built.yaml` directly — it is generated.
- Run `python3 scripts/build_litellm_config.py` after changes.
- Model IDs marked with `# verified 2026-04-06` have been validated against live provider APIs.
- Routing strategy: `latency-based-routing` (fastest provider first, 6 retries, 30s cooldown).
- Two sensitivity tiers: `tier-*-sensitive` (Western ZDR providers only) and `tier-*-nonsensitive` (all providers including Chinese/open-weight).
- OpenRouter sensitive-tier guard: `zdr: true`, `data_collection: deny`, `allow_fallbacks: false`, 43+ whitelisted Western providers.

## Services

- All services run natively (no Docker Compose). LiteLLM runs as a Python process, approval bridge has its own launcher.
- Use `./stack.sh start` to build and boot everything, `./stack.sh stop` to tear down.
- All state, builds, and tool installs live under `STACK_ROOT` (default: `/Volumes/macmini1`).
- Colima home is `$STACK_ROOT/nemoclaw-stack/colima` — do not use the default `~/.colima` path.
- LiteLLM serves on HTTPS:4000 with a self-signed TLS cert (auto-generated on first start).

## Secrets

- Never commit `.env` files or real API keys. They are gitignored.
- Use `.env.example` files as templates.
- API keys can live in `services/litellm/.env` (default) or macOS Keychain (service: `nemoclaw-stack`).
- To import keys into Keychain: `./scripts/store-secrets.sh`
- To use Keychain at startup: `./stack.sh start --secrets keychain`
- Telegram/webhook secrets live in `.env` at repo root.
- Honeypot secrets in `tests/honeypot/data/secrets/` are all FAKE-prefixed — not real keys.

## Mediator

The mediator is a UDS-based syscall mediation layer with 11 syscalls, per-data-type taint analysis, and 8 scrubber types.

### Architecture

- **mediator-daemon**: standalone Rust binary, runs inside the sandbox container alongside the OpenClaw gateway.
- **mediator-cli**: shell tool for agents to call mediator syscalls from bash.
- Both binaries require the `mediator-tools` cargo feature: `cargo build --features mediator-tools --bin mediator-cli --bin mediator-daemon`.
- Socket: `/run/openshell/mediator.sock`, DB: SQLite, Token: `/run/openshell/mediator.sock.token`.

### 11 Syscalls

| Category | Syscalls |
|----------|----------|
| Network | `http_request` |
| Policy CRUD | `policy_propose`, `policy_list`, `policy_get`, `revoke_policy` |
| Process | `fork_with_policy`, `signal`, `request_port` |
| IPC | `ipc_send`, `ipc_connect` |
| Discovery | `ps` |

### Taint Analysis

- Per-data-type-tag static analysis at `policy_propose` time.
- Detects the lethal trifecta: private data + untrusted content + external communication.
- IPC scrubbers with `de_taints: true` break the taint chain.
- Implicit sensitivity: data written by clean processes (no untrusted input) is presumed sensitive.
- Compromise propagation pre-computed at propose time, materialized at fork time.

### 8 Scrubbers

| Scrubber | Purpose | de_taints |
|----------|---------|-----------|
| `regex_pii` | SSN, email, phone, CC patterns | yes |
| `field_pii` | Redact/hash specific JSON paths | yes |
| `ner_pii` | Presidio NER sidecar with regex fallback | yes |
| `schema_enforcer` | Reject messages not matching JSON schema | yes |
| `canary` | Inject/detect canary tokens for exfil detection | no |
| `delimiter` | Wrap untrusted content in boundary tags | no |
| `instruction_strip` | Remove prompt injection patterns | no |
| `passthrough` | No-op | no |

### Init Policy

Init (the coordinator) has no HTTP access except the inference endpoint (configured via `INIT_INFERENCE_ENDPOINT`). No sensitive mounts, no bind_ports. Can fork any child policy, IPC with any workflow, signal any workflow. All mutating syscalls require human approval when the approval bridge is configured.

### NemoClaw Integration

The mediator-daemon is started by `nemoclaw-start.sh` (NemoClaw's container entrypoint) before the gateway. It writes `MEDIATOR_SOCKET` and `MEDIATOR_TOKEN` to the sandbox user's bashrc/profile. The `mediator-cli` binary is uploaded to `/sandbox/mediator-cli` during `stack.sh create`.

### Cross-Compilation

mediator-cli and mediator-daemon must be cross-compiled for Linux aarch64 (the sandbox runs Debian in a Colima VM). Use `cargo-zigbuild`:

```bash
rustup target add aarch64-unknown-linux-musl
cargo install cargo-zigbuild
cargo zigbuild --release --target aarch64-unknown-linux-musl -p openshell-sandbox --features mediator-tools --bin mediator-cli --bin mediator-daemon
```

## stack.sh Commands

| Command | Description |
|---------|-------------|
| `start [--secrets keychain]` | Build infrastructure, start LiteLLM + Colima, verify models |
| `create [--boot-prompt <file>]` | Create sandbox, upload mediator binaries + guide, inject AGENTS.md |
| `stop [--clean]` | Graceful teardown (`--clean` wipes state/certs/secrets) |
| `ps` | Component status (Colima, LiteLLM, gateway, sandbox, bridge, mediator) |
| `health [--full]` | Test endpoints + tier routing (`--full` tests all OpenRouter providers) |
| `verify-models` | Verify all model IDs against live provider APIs (blocks start on failure) |
| `env` | Print shell exports for manual use |
| `run <cmd...>` | Run a command with stack env loaded |

## Testing

### Mediator (Rust, in ~/repos/OpenShell)

- 167 tests total: 141 unit + 10 mediator integration + 10 trifecta e2e + 5 workflow e2e + 1 fullstack
- `cargo test -p openshell-sandbox --lib mediator` — unit tests (scrubbers, taint analysis, store, daemon)
- `cargo test -p openshell-sandbox --test mediator_integration` — UDS protocol tests
- `cargo test -p openshell-sandbox --test trifecta_e2e` — taint enforcement over UDS
- `cargo test -p openshell-sandbox --test workflow_e2e` — doc workflow scenarios
- `cargo test -p openshell-sandbox --test fullstack_workflow_e2e` — all workflows in one scenario

### Stack

- `./stack.sh health` — LiteLLM proxy + direct providers + model tier routing
- `./stack.sh health --full` — also test all 43+ OpenRouter providers individually
- `./stack.sh verify-models` — verify every model ID against live APIs

### Honeypot

- Boot with: `./stack.sh create --boot-prompt tests/boot-prompts/honeypot-ops.md`
- WhatsApp bridge: `python3 tests/honeypot/bridge_sync.py` (runs on host, syncs via kubectl cp)
- Agent: `tests/honeypot/agent_sandbox.py` (runs inside sandbox)

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/) format.
- Never mention AI agents in commit messages.

## Python

- Use `uv` when available, fall back to `pip3`.
- The LiteLLM build script requires `pyyaml`.
