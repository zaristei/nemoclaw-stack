#!/usr/bin/env python3
"""
Builds litellm_config.built.yaml from three source files:
  models.yaml            — model list
  trusted_providers.yaml — OpenRouter western-only whitelist
  litellm_config.yaml    — router + general settings

Uses string substitution (not YAML parse+dump) so the built file preserves
all comments, section headers, and anchor names from the source files.

Run before starting LiteLLM whenever any source file changes:
  python3 scripts/build_litellm_config.py

LiteLLM should then be started with the built config (docker-compose does this automatically).
"""
import re
import sys
import yaml
from pathlib import Path

CONFIG_DIR = Path(__file__).parent.parent / "services" / "litellm" / "config"
PROVIDERS_FILE = CONFIG_DIR / "trusted_providers.yaml"
MODELS_FILE = CONFIG_DIR / "models.yaml"
SETTINGS_FILE = CONFIG_DIR / "litellm_config.yaml"
OUTPUT_FILE = CONFIG_DIR / "litellm_config.built.yaml"

# Matches the sentinel line, capturing its leading whitespace.
# e.g.: "          order: []  # populated from trusted_providers.yaml ..."
SENTINEL_RE = re.compile(r'^( +)order: \[\].*trusted_providers.*$', re.MULTILINE)


def build_order_block(indent: str, providers: list[str]) -> str:
    item_indent = indent + "  "
    lines = [f"{indent}order:"]
    lines += [f"{item_indent}- {p}" for p in providers]
    return "\n".join(lines)


def main():
    for path in (PROVIDERS_FILE, MODELS_FILE, SETTINGS_FILE):
        if not path.exists():
            print(f"ERROR: {path} not found", file=sys.stderr)
            sys.exit(1)

    with open(PROVIDERS_FILE) as f:
        providers = yaml.safe_load(f)

    if not isinstance(providers, list):
        print("ERROR: trusted_providers.yaml must be a YAML list", file=sys.stderr)
        sys.exit(1)

    models_text = MODELS_FILE.read_text()
    settings_text = SETTINGS_FILE.read_text()

    matches = SENTINEL_RE.findall(models_text)
    if not matches:
        print("ERROR: sentinel 'order: []  # populated from trusted_providers...' not found in models.yaml", file=sys.stderr)
        sys.exit(1)

    def replacer(m):
        return build_order_block(m.group(1), providers)

    models_text = SENTINEL_RE.sub(replacer, models_text)

    output = models_text.rstrip("\n") + "\n\n" + settings_text
    OUTPUT_FILE.write_text(output)

    n_injections = len(matches)
    print(f"Built {OUTPUT_FILE}  ({len(providers)} trusted providers, {n_injections} injection point(s))")


if __name__ == "__main__":
    main()
