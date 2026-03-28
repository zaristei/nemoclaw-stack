# Agent Instructions

This repo orchestrates NemoClaw and OpenShell services for local development and deployment. Follow these instructions when contributing.

## Project Structure

| Path | Purpose |
|------|---------|
| `openshell/` | OpenShell submodule — do not edit directly, work in `~/repos/OpenShell` |
| `nemoclaw/` | NemoClaw submodule — do not edit directly, work in `~/repos/NemoClaw` |
| `services/litellm/` | LiteLLM proxy config and env |
| `services/approval-bridge/` | Python webhook-to-Telegram bridge |
| `scripts/` | Build and utility scripts |
| `start.sh` | Colima + compose launcher |

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

- Services run via Docker Compose through Colima.
- Use `./start.sh` to manage the stack. It handles Colima lifecycle and config rebuilds.
- Colima home is `/Volumes/macmini1/config/colima` — do not use the default `~/.colima` path.

## Secrets

- Never commit `.env` files. They are gitignored.
- Use `.env.example` files as templates.
- API keys live in `services/litellm/.env`. Telegram/webhook secrets live in `.env` at repo root.

## Testing

- Approval bridge: `cd services/approval-bridge && python3 -m pytest test_bridge.py`
- LiteLLM: start the proxy and test with `curl http://localhost:4000/v1/chat/completions`

## Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/) format.
- Never mention AI agents in commit messages.

## Python

- Use `uv` when available, fall back to `pip3`.
- The LiteLLM build script requires `pyyaml`.
