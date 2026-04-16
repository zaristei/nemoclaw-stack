#!/bin/sh
# agent-bootstrap.sh — set up an OpenClaw agent workspace and run --local
#
# Called by fork_with_policy as the child's launch command. Expects:
#   $WORKFLOW_ID    — set by the mediator daemon
#   $POLICY_NAME    — set by the mediator daemon
#   $MEDIATOR_TOKEN — set by the mediator daemon
#   $HOME           — set by the mediator daemon (instance dir)
#   $1              — the task message for the agent
#
# Creates a per-workflow OpenClaw config in $HOME/.openclaw/ (the child UID
# can't write to root-owned /sandbox/.openclaw). Does NOT call
# `openclaw agents add` — that command triggers gateway hot-reload and
# crashes the main container process. Instead, we construct the agent
# profile directly in the config JSON.

WORKFLOW_DIR="/sandbox/.mediator/workflows/${WORKFLOW_ID}"
POLICY_WORKSPACE="/sandbox/.mediator/policies/${POLICY_NAME}/workspace"
AGENT_DIR="${WORKFLOW_DIR}/agent"
# HOME is set by the mediator daemon to the instance dir.
# OpenClaw reads config from $HOME/.openclaw/openclaw.json.
OC_DIR="${HOME}/.openclaw"

# Create dirs (child UID owns workflow dir via daemon chown)
mkdir -p "$POLICY_WORKSPACE" "$AGENT_DIR/sessions" "$OC_DIR" 2>/dev/null

# Build the child's config JSON. Start from the base config but:
# 1. Patch inference.local → host.docker.internal:4000 (child can't resolve internal hostname)
# 2. Add the child agent profile to agents.list
# 3. Remove channels/gateway/plugins (child runs --local, no gateway)
if [ -f /sandbox/.openclaw/openclaw.json ]; then
    python3 -c "
import json, sys
with open('/sandbox/.openclaw/openclaw.json') as f:
    cfg = json.load(f)

# Patch inference endpoint
providers = cfg.get('models', {}).get('providers', {})
for p in providers.values():
    if isinstance(p, dict) and 'inference.local' in p.get('baseUrl', ''):
        p['baseUrl'] = p['baseUrl'].replace('https://inference.local', 'http://host.docker.internal:4000')
        # The gateway substitutes the real API key; for --local we need it
        # explicitly. Read from key file written by stack.sh create.
        import os
        litellm_key = ''
        for kf in ['/sandbox/.mediator/litellm.key', os.environ.get('LITELLM_KEY_FILE', '')]:
            try:
                litellm_key = open(kf).read().strip()
                if litellm_key: break
            except: pass
        if not litellm_key:
            litellm_key = os.environ.get('LITELLM_KEY', p.get('apiKey', 'unused'))
        if litellm_key and litellm_key != 'unused':
            p['apiKey'] = litellm_key

# Add child agent profile
agents = cfg.setdefault('agents', {})
agent_list = agents.setdefault('list', [])
agent_list.append({
    'id': '$WORKFLOW_ID',
    'name': '$WORKFLOW_ID',
    'workspace': '$POLICY_WORKSPACE',
    'agentDir': '$AGENT_DIR',
    'model': agents.get('defaults', {}).get('model', {}).get('primary', 'inference/tier-sonnet-sensitive')
})

# Remove sections that would conflict with --local
for key in ['channels', 'gateway', 'plugins']:
    cfg.pop(key, None)

# Inject Brave Search key if available (stored by stack.sh, not in base config)
import os
brave_key = ''
for kf in ['/sandbox/.mediator/brave.key']:
    try:
        brave_key = open(kf).read().strip()
        if brave_key: break
    except: pass
if brave_key:
    cfg.setdefault('tools', {}).setdefault('web', {})['search'] = {
        'enabled': True, 'provider': 'brave', 'apiKey': brave_key
    }
    cfg['tools']['web']['fetch'] = {'enabled': True}

with open('$OC_DIR/openclaw.json', 'w') as f:
    json.dump(cfg, f, indent=2)
print('Config written', file=sys.stderr)
" 2>&1
fi

# Symlink shared read-only dirs from the base data dir so extensions and
# skills are available to the child.
for dir in extensions skills; do
    if [ -e "/sandbox/.openclaw-data/$dir" ] && [ ! -e "$OC_DIR/$dir" ]; then
        ln -s "/sandbox/.openclaw-data/$dir" "$OC_DIR/$dir" 2>/dev/null
    fi
done

# Child UID outbound traffic is iptables-restricted to the L7 proxy.
# Route all HTTP(S) through the proxy so the UidPolicyRegistry allowlist
# is enforced. The proxy runs at 10.200.0.1:3128 (veth host side).
export HTTP_PROXY="http://10.200.0.1:3128"
export HTTPS_PROXY="http://10.200.0.1:3128"
export http_proxy="http://10.200.0.1:3128"
export https_proxy="http://10.200.0.1:3128"
export NO_PROXY="localhost,127.0.0.1,10.200.0.1"
export NODE_TLS_REJECT_UNAUTHORIZED=0

# Run the agent turn. --local runs in-process (no gateway needed).
exec openclaw agent --agent "$WORKFLOW_ID" --local -m "$1" --json
