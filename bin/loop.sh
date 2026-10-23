#!/usr/bin/env bash
# Read-only coordinator cycle: tells a polling Planner whether anything needs it (so it is not woken for nothing). Reads each recent
# Run's tasks, workers and messages from Orca; runs the oracle on tasks that finished as succeeded. It never acks, releases, sends or writes to Orca.
# Usage:  loop.sh [--run <id> ...] [--since-hours N] [--force] [--no-verify]
# Without settings.oracle.enabled (true) it adds --no-verify by itself: it only reads Orca and runs no command. Uses settings.oracle {timeout, maxLoad, waitMax}.
# Result: JSON {ts, dry_run, wake, reasons, runs} on stdout; `wake` is the decision. Exit 0 on a completed cycle, 2 = bad usage, 3 = no python3 >= 3.8.
# ORCA_ROLES_PYTHON picks the interpreter; the oracle's verify.json lives under ${ORCA_ROLES_ORACLE_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/orca-roles/oracle}.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
PY="${ORCA_ROLES_PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1 || ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
  echo "loop.sh: needs python3 >= 3.8 (looked for '$PY' on the PATH). Install it or set ORCA_ROLES_PYTHON to a newer interpreter." >&2
  exit 3
fi

ARGS=(); NOVERIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) [ $# -ge 2 ] || { echo "loop.sh: --run needs a value" >&2; exit 2; }; ARGS+=(--run "$2"); shift 2;;
    --since-hours) [ $# -ge 2 ] || { echo "loop.sh: --since-hours needs a value" >&2; exit 2; }; ARGS+=(--since-hours "$2"); shift 2;;
    --force) ARGS+=(--force); shift;;
    --no-verify) NOVERIFY=1; shift;;
    -h|--help) sed -n 2,7p "$0"; exit 0;;
    *) echo "loop.sh: unknown option: $1" >&2; exit 2;;
  esac
done

CFG="${ORCA_ROLES_CONFIG:-}"
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then CFG="$(mktemp)"; trap 'rm -f "$CFG"' EXIT; merged_config . > "$CFG" 2>/dev/null || echo '{}' > "$CFG"; fi
ocfg() {  # <key> → the value of settings.oracle.<key>, or empty
  jq -r --arg k "$1" '(.settings.oracle? | objects | .[$k]?) // empty | tostring' "$CFG" 2>/dev/null
}
isnum() { case "$1" in ''|*[!0-9.]*|*.*.*|.) return 1;; *) return 0;; esac; }
[ "$(jq -r '(.settings.oracle? | objects | .enabled?) == true' "$CFG" 2>/dev/null)" = true ] || NOVERIFY=1
[ "$NOVERIFY" = 0 ] || ARGS+=(--no-verify)
for k in timeout:--timeout:int maxLoad:--max-load:num waitMax:--wait-max:int; do
  name="${k%%:*}"; rest="${k#*:}"; v="$(ocfg "$name")"
  [ "${rest#*:}" = int ] && v="${v%%.*}"   # timeout and waitMax are whole seconds for the python side
  if isnum "$v"; then ARGS+=("${rest%%:*}" "$v"); elif [ -n "$v" ]; then echo "loop.sh: settings.oracle.$name must be a non-negative number (got '$v'); using the default" >&2; fi
done

PYTHONDONTWRITEBYTECODE=1 "$PY" "$KIT/bin/oracle/loop.py" ${ARGS[@]+"${ARGS[@]}"}
