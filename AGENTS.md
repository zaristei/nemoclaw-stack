# Agent Instructions

This repo orchestrates NemoClaw and OpenShell services for local development and deployment. Follow these instructions when contributing.

## Project Structure

| Path | Purpose |
|------|---------|
| `openshell/` | OpenShell submodule — do not edit directly, work in `~/repos/OpenShell` |
| `nemoclaw/` | NemoClaw submodule — do not edit directly, work in `~/repos/NemoClaw` |
| `services/litellm/` | LiteLLM proxy config and env |
| `services/approval-bridge/` | Python webhook-to-Telegram bridge |
| `scripts/` | Build, config, and secrets scripts |
| `stack.sh` | Unified CLI: start, stop, ps, health |

## Submodule Workflow

- Never commit changes inside `openshell/` or `nemoclaw/` directories directly.
- Make changes in the standalone repos (`~/repos/OpenShell`, `~/repos/NemoClaw`), push to fork, then update the submodule pointer here.
- To update a submodule: `cd <submodule> && git fetch fork && git checkout fork/<branch>`, then commit from the repo root.

## LiteLLM Config

- Edit source files in `services/litellm/config/` (models.yaml, litellm_config.yaml, trusted_providers.yaml).
- Never edit `litellm_config.built.yaml` directly — it is generated.
- Run `python3 scripts/build_litellm_config.py` after changes.
- Model IDs marked with `# verify` comments have been validated against provider APIs. Remove the comment only after confirming the ID works.

## Services

- All services run natively (no Docker Compose). LiteLLM runs as a Python process, approval bridge has its own launcher.
- Use `./stack.sh start` to build and boot everything, `./stack.sh stop` to tear down.
- All state, builds, and tool installs live under `STACK_ROOT` (default: `/Volumes/macmini1`).
- Colima home is `$STACK_ROOT/nemoclaw-stack/colima` — do not use the default `~/.colima` path.

## Secrets

- Never commit `.env` files. They are gitignored.
- Use `.env.example` files as templates.
- API keys can live in `services/litellm/.env` (default) or macOS Keychain (service: `nemoclaw-stack`).
- To import keys into Keychain: `./scripts/store-secrets.sh`
- To use Keychain at startup: `./stack.sh start --secrets keychain`
- Telegram/webhook secrets live in `.env` at repo root.

## Testing

- Stack health (LiteLLM + all providers + Docker network): `./stack.sh health`
- Approval bridge: `cd services/approval-bridge && python3 -m pytest test_bridge.py`

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/) format.
- Never mention AI agents in commit messages.

## Python

- Use `uv` when available, fall back to `pip3`.
- The LiteLLM build script requires `pyyaml`.
