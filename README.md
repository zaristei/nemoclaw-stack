# nemoclaw-stack

Deployment orchestration for [NemoClaw](https://github.com/NVIDIA/NemoClaw) and [OpenShell](https://github.com/NVIDIA/OpenShell). Composes auxiliary services (LLM proxy, approval bridge) alongside the core sandbox runtime.

## Architecture

```
nemoclaw-stack/
├── openshell/          # OpenShell submodule (sandbox runtime, policy engine)
├── nemoclaw/           # NemoClaw submodule (agent CLI, onboarding)
├── services/
│   ├── litellm/        # LiteLLM proxy — tiered model routing
│   └── approval-bridge/# Telegram approval bridge for policy webhooks
├── scripts/
│   └── build_litellm_config.py  # Merges model + provider configs
├── docker-compose.yml
└── start.sh            # Colima + compose launcher
```

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules <repo-url>
cd nemoclaw-stack

# Copy and fill in secrets
cp .env.example .env
cp services/litellm/.env.example services/litellm/.env
# Edit both .env files with your API keys

# Start everything (handles Colima, config build, and compose)
./start.sh
```

## Services

### LiteLLM Proxy (port 4000)

Tiered model routing with sensitivity-aware provider selection.

| Tier | Sensitive | Non-sensitive |
|------|-----------|---------------|
| Opus | Western providers only | + OpenRouter open-weight/Chinese models |
| Sonnet | Western providers only | + OpenRouter open-weight/Chinese models |
| Haiku | Western providers only | + OpenRouter open-weight/Chinese models |

Sensitive tiers restrict to Anthropic, OpenAI, Google, xAI, Mistral, and NVIDIA (via whitelisted OpenRouter providers). Non-sensitive tiers add DeepSeek, Qwen, GLM, Llama, and others.

**Config files** (`services/litellm/config/`):
- `models.yaml` — model list with YAML anchors for DRY sensitive/nonsensitive inheritance
- `trusted_providers.yaml` — OpenRouter western-only provider whitelist
- `litellm_config.yaml` — router settings and fallback chains

After editing config sources, rebuild: `python3 scripts/build_litellm_config.py`

### Approval Bridge (port 8090)

Receives HMAC-signed webhooks from OpenShell's approval API and presents them as Telegram inline-button prompts. Approvers tap approve/deny in Telegram; the bridge holds the decision until OpenShell polls for it.

Requires: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `WEBHOOK_SECRET` in `.env`.

## start.sh

```bash
./start.sh              # start all services
./start.sh litellm      # start specific service
./start.sh down          # stop everything
./start.sh ps            # show status
./start.sh logs litellm  # tail logs
```

Handles Colima startup (with `COLIMA_HOME=/Volumes/macmini1/config/colima`), docker-compose plugin linking, and auto-rebuilds the LiteLLM config when source files are newer than the built output.

## Submodules

| Submodule | Upstream | Branch |
|-----------|----------|--------|
| `openshell/` | NVIDIA/OpenShell | `feat/policy-audit-log` |
| `nemoclaw/` | NVIDIA/NemoClaw | `main` |

Update submodules: `git submodule update --remote`

## Environment Files

| File | Purpose |
|------|---------|
| `.env` | Approval bridge: Telegram bot token, chat ID, webhook secret |
| `services/litellm/.env` | LiteLLM: API keys for Anthropic, OpenAI, Google, xAI, Mistral, OpenRouter |

Both are gitignored. Copy from their `.env.example` counterparts.
