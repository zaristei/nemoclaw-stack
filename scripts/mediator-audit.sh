#!/usr/bin/env bash
# mediator-audit — query the mediator's audit log as ground truth.
#
# Every mediator syscall is recorded in the audit_log table regardless of
# outcome. Use this script to verify what an agent actually called against
# what the agent claims to have called. If a syscall claim does not appear
# in the audit log, it did not happen.
#
# Usage:
#   ./scripts/mediator-audit.sh [options]
#
# Options:
#   -w, --workflow-id <id>   Filter by workflow_id (exact match)
#   -s, --syscall <name>     Filter by syscall name (exact match)
#   -r, --result <r>         Filter by result (allowed|denied)
#   --since <unix-ts>        Only entries with timestamp >= this value
#   --since-min <n>          Only entries from the last N minutes
#   -n, --limit <n>          Max entries to return (default: 50)
#   --json                   Output JSON instead of table
#   --with-args              Include args column in table output
#   --sandbox <name>         Sandbox name (default: my-assistant or
#                            $NEMOCLAW_SANDBOX_NAME)
#   --db <path>              DB path inside sandbox
#                            (default: /sandbox/.mediator/mediator.db)
#   -h, --help               Show this help

set -euo pipefail

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-my-assistant}"
DB_PATH="/sandbox/.mediator/mediator.db"
LIMIT=50
WORKFLOW_ID=""
SYSCALL=""
RESULT_FILTER=""
SINCE=""
WITH_ARGS=0
JSON=0

usage() {
    # Print the leading comment block (everything from line 2 up to the first
    # non-comment, non-blank line), stripping the leading "# " prefix.
    awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else if ($0 == "") { next } else { exit } }' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--workflow-id) WORKFLOW_ID="$2"; shift 2 ;;
        -s|--syscall)     SYSCALL="$2"; shift 2 ;;
        -r|--result)      RESULT_FILTER="$2"; shift 2 ;;
        --since)          SINCE="$2"; shift 2 ;;
        --since-min)      SINCE=$(( $(date +%s) - $2 * 60 )); shift 2 ;;
        -n|--limit)       LIMIT="$2"; shift 2 ;;
        --json)           JSON=1; shift ;;
        --with-args)      WITH_ARGS=1; shift ;;
        --sandbox)        SANDBOX_NAME="$2"; shift 2 ;;
        --db)             DB_PATH="$2"; shift 2 ;;
        -h|--help)        usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

# Build WHERE clause from filters. All filters AND together.
where_parts=()
if [[ -n "$WORKFLOW_ID" ]]; then
    # SQL string-escape: double single quotes.
    esc=$(printf '%s' "$WORKFLOW_ID" | sed "s/'/''/g")
    where_parts+=("workflow_id = '$esc'")
fi
if [[ -n "$SYSCALL" ]]; then
    esc=$(printf '%s' "$SYSCALL" | sed "s/'/''/g")
    where_parts+=("syscall = '$esc'")
fi
if [[ -n "$RESULT_FILTER" ]]; then
    esc=$(printf '%s' "$RESULT_FILTER" | sed "s/'/''/g")
    where_parts+=("result = '$esc'")
fi
if [[ -n "$SINCE" ]]; then
    # timestamp is stored as TEXT (unix seconds), so cast for numeric compare.
    where_parts+=("CAST(timestamp AS INTEGER) >= $SINCE")
fi

WHERE=""
if (( ${#where_parts[@]} > 0 )); then
    WHERE="WHERE $(IFS=' AND '; echo "${where_parts[*]}")"
fi

# Build the query. Order by id DESC so most recent come first; LIMIT in SQL.
if (( JSON == 1 )); then
    QUERY=".mode json
SELECT id, timestamp, workflow_id, syscall, args, result, policy_used, details
FROM audit_log
$WHERE
ORDER BY id DESC
LIMIT $LIMIT;"
else
    if (( WITH_ARGS == 1 )); then
        cols="id, datetime(CAST(timestamp AS INTEGER), 'unixepoch') AS time, workflow_id, syscall, result, policy_used, substr(args, 1, 60) AS args, substr(coalesce(details, ''), 1, 40) AS details"
    else
        cols="id, datetime(CAST(timestamp AS INTEGER), 'unixepoch') AS time, workflow_id, syscall, result, policy_used, substr(coalesce(details, ''), 1, 40) AS details"
    fi
    QUERY=".mode column
.headers on
.width 5 19 16 18 8 16 40
SELECT $cols
FROM audit_log
$WHERE
ORDER BY id DESC
LIMIT $LIMIT;"
fi

# Pull the db out of the sandbox and query it on the host. This avoids needing
# sqlite3 inside the sandbox image and works against any openshell-cli version
# that has `sandbox download`. Note: WAL changes that haven't been checkpointed
# may not be visible — for a strict point-in-time snapshot the daemon should
# be quiesced first, but for "did this syscall happen?" queries it's fine.

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "error: sqlite3 not installed on host" >&2
    echo "  install with: brew install sqlite (preinstalled on macOS)" >&2
    exit 1
fi

tmpdir=$(mktemp -d -t mediator-audit.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

if ! openshell sandbox download "$SANDBOX_NAME" "$DB_PATH" "$tmpdir" >/dev/null 2>&1; then
    echo "error: failed to download $DB_PATH from sandbox '$SANDBOX_NAME'" >&2
    echo "  is the sandbox running and is the mediator daemon started?" >&2
    echo "  (try: ./stack.sh ps)" >&2
    exit 1
fi

local_db="$tmpdir/$(basename "$DB_PATH")"
if [[ ! -f "$local_db" ]]; then
    echo "error: download succeeded but $local_db not found" >&2
    ls -la "$tmpdir" >&2
    exit 1
fi

# Also try to pull the WAL file if it exists, so we see uncommitted writes.
# Failure is non-fatal — old DB-only views are still useful.
openshell sandbox download "$SANDBOX_NAME" "${DB_PATH}-wal" "$tmpdir" >/dev/null 2>&1 || true
openshell sandbox download "$SANDBOX_NAME" "${DB_PATH}-shm" "$tmpdir" >/dev/null 2>&1 || true

# Pipe via stdin so sqlite3 dot-commands (.mode, .headers, .width) are
# processed as commands, not SQL. Passing them as the argv query string
# would error with "near .: syntax error".
printf '%s\n' "$QUERY" | sqlite3 "$local_db"
