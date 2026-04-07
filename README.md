# nemoclaw-stack

Deployment orchestration for [NemoClaw](https://github.com/NVIDIA/NemoClaw) and [OpenShell](https://github.com/NVIDIA/OpenShell). Composes auxiliary services (LLM proxy, mediator, approval bridge) alongside the core sandbox runtime.

## Architecture

```
nemoclaw-stack/
├── openshell/              # OpenShell submodule (sandbox runtime, mediator)
├── nemoclaw/               # NemoClaw submodule (agent CLI, onboarding)
├── services/
│   ├── litellm/            # LiteLLM proxy — tiered model routing (HTTPS)
│   └── approval-bridge/    # Telegram approval bridge for policy webhooks
├── scripts/
│   ├── build_litellm_config.py   # Merges model + provider configs
│   ├── resolve-secrets.sh        # Secret resolution (env or Keychain)
│   ├── store-secrets.sh          # Import secrets to macOS Keychain
│   └── verify-models.sh          # Verify model IDs against live APIs
├── tests/
│   ├── honeypot/           # Red team honeypot (fake PII, WhatsApp bridge)
│   └── boot-prompts/       # Test system prompts for sandbox injection
├── docs/
│   ├── eight-syscalls.html # Design doc: 11 mediator syscalls
│   └── agent-syscall-guide.md  # Agent system prompt: syscalls + policy design
└── stack.sh                # Unified CLI
```

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules <repo-url>
cd nemoclaw-stack

# Copy and fill in secrets
cp services/litellm/.env.example services/litellm/.env
# Edit with your API keys (Anthropic, OpenAI, Google, xAI, Mistral, OpenRouter)

# Start everything (Colima, LiteLLM, OpenShell, model verification)
./stack.sh start

# Create sandbox with NemoClaw
./stack.sh create

# Or with a test system prompt
./stack.sh create --boot-prompt tests/boot-prompts/workflow-test.md
```

## Services

### LiteLLM Proxy (HTTPS, port 4000)

Tiered model routing with sensitivity-aware provider selection. Self-signed TLS cert auto-generated on first start.

| Tier | Sensitive (ZDR) | Non-sensitive |
|------|-----------------|---------------|
| Opus | Anthropic, OpenAI, Google, xAI, Mistral | + DeepSeek, Qwen, Kimi |
| Sonnet | Same + NVIDIA Nemotron | + DeepSeek, Qwen, GLM, Llama |
| Haiku | Same (no NVIDIA yet) | + DeepSeek, Qwen, Llama, GLM, MiniMax |

Sensitive tiers enforce zero-data-retention via OpenRouter `zdr: true` + 43-provider whitelist. Routing: `latency-based-routing`, 6 retries, 30s cooldown, cross-tier fallback (opus→sonnet→haiku, never cross sensitivity).

**Config** (`services/litellm/config/`):
- `models.yaml` — model list (YAML anchors for DRY inheritance)
- `trusted_providers.yaml` — OpenRouter western-only whitelist
- `litellm_config.yaml` — router + general settings

Rebuild after editing: `python3 scripts/build_litellm_config.py`

### Mediator (UDS, inside sandbox)

11-syscall policy engine running as `mediator-daemon` inside the sandbox container.

| Category | Syscalls |
|----------|----------|
| Policy CRUD | `policy_propose`, `policy_list`, `policy_get`, `revoke_policy` |
| Process | `fork_with_policy`, `signal`, `request_port` |
| IPC | `ipc_send`, `ipc_connect` |
| Discovery | `ps` |

**Taint analysis:** Per-data-type-tag static analysis at `policy_propose` time. Detects the lethal trifecta (private data + untrusted content + external communication). 8 scrubber types break taint chains on IPC.

**Agent access:** `mediator-cli` binary inside the sandbox. See `docs/agent-syscall-guide.md`.

### Approval Bridge (port 8090)

Receives webhooks from the mediator and presents policy proposals as Telegram inline-button prompts. Also handles mediator syscall approval for init process.

Requires: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `WEBHOOK_SECRET` in `.env`.

## stack.sh

```bash
./stack.sh start                    # Build + start infrastructure
./stack.sh create                   # Create sandbox + onboard NemoClaw
./stack.sh create --boot-prompt F   # Create with injected AGENTS.md
./stack.sh stop                     # Graceful teardown
./stack.sh stop --clean             # Teardown + wipe state/certs/secrets
./stack.sh ps                       # Component status
./stack.sh health                   # Quick: endpoints + tier routing
./stack.sh health --full            # Also test all OpenRouter providers
./stack.sh verify-models            # Verify every model ID against live APIs
./stack.sh env                      # Print shell exports
./stack.sh run <cmd>                # Run command with stack env
```

`start` builds OpenShell CLI + mediator binaries, starts LiteLLM with TLS, verifies all model IDs (blocks on failure), and builds the cluster image. `create` onboards NemoClaw, uploads mediator-cli + mediator-daemon + agent syscall guide to the sandbox, and optionally injects a boot prompt.

## Submodules

| Submodule | Fork | Branch |
|-----------|------|--------|
| `openshell/` | zaristei/OpenShell | `feat/mediator-init-bootstrap` |
| `nemoclaw/` | zaristei/NemoClaw | `feat/nemoclaw-home-env-v2` |

Update: `cd <submodule> && git fetch fork && git checkout fork/<branch>`, then commit from repo root.

## Testing

### Mediator (161 Rust tests)

```bash
cd ~/repos/OpenShell
cargo test -p openshell-sandbox --lib mediator           # 135 unit tests
cargo test -p openshell-sandbox --test mediator_integration  # 10 protocol tests
cargo test -p openshell-sandbox --test trifecta_e2e          # 10 taint tests
cargo test -p openshell-sandbox --test workflow_e2e          # 5 doc workflow tests
cargo test -p openshell-sandbox --test fullstack_workflow_e2e # 1 full lifecycle test
```

### Stack health

```bash
./stack.sh health          # LiteLLM + providers + tier routing
./stack.sh health --full   # + all 43 OpenRouter providers individually
./stack.sh verify-models   # Every model ID against live APIs
```

### Honeypot (red team)

```bash
./stack.sh create --boot-prompt tests/boot-prompts/honeypot-ops.md
# WhatsApp bridge: python3 tests/honeypot/bridge_sync.py (host)
# Agent: tests/honeypot/agent_sandbox.py (inside sandbox)
# Twilio sandbox: text "join equator-gather" to +1 415 523 8886
```

## Environment Files

| File | Purpose |
|------|---------|
| `.env` | Approval bridge: Telegram bot token, chat ID, webhook secret |
| `services/litellm/.env` | LiteLLM: API keys for all providers + master key |

Both are gitignored. Copy from `.env.example` counterparts.
