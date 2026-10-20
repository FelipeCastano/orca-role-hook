#!/usr/bin/env bash
# Optional executable oracle for Dev's work: runs the task spec's acceptance command (allowlisted) in this worktree and checks that the
# tests were not cheated (deleted, skipped, weakened) against the base. The Planner runs it after a Dev worker_done.
# Usage (from the worktree):  oracle.sh --task <id> [--spec-file <file>] [--base <ref>] [--dry-run] [--no-wait]
# Reads settings.oracle {enabled, maxLoad, waitMax, timeout, retries} from the worktree's configuration. It runs even when
# "enabled" is false (it is a tool; "enabled" only makes the Planner use it) and says so on stderr.
# Result: JSON on stdout and verify.json under ${ORCA_ROLES_ORACLE_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/orca-roles/oracle}/<task>/.
# Exit: verify_task.py's (0 = pass and no cheat, 1 = anything else), 2 = bad usage, 3 = no python3 >= 3.8. ORCA_ROLES_PYTHON picks the interpreter.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
PY="${ORCA_ROLES_PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1 || ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
  echo "oracle.sh: needs python3 >= 3.8 (looked for '$PY' on the PATH). Install it or set ORCA_ROLES_PYTHON to a newer interpreter." >&2
  exit 3
fi

TASK=""; SPEC=""; BASE=""; EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --task) [ $# -ge 2 ] || { echo "oracle.sh: --task needs a value" >&2; exit 2; }; TASK="$2"; shift 2;;
    --spec-file) [ $# -ge 2 ] || { echo "oracle.sh: --spec-file needs a value" >&2; exit 2; }; SPEC="$2"; shift 2;;
    --base) [ $# -ge 2 ] || { echo "oracle.sh: --base needs a value" >&2; exit 2; }; BASE="$2"; shift 2;;
    --dry-run|--no-wait) EXTRA+=("$1"); shift;;
    -h|--help) sed -n 2,9p "$0"; exit 0;;
    *) echo "oracle.sh: unknown option: $1" >&2; exit 2;;
  esac
done
[ -n "$TASK" ] || { echo "oracle.sh: --task <id> is required" >&2; exit 2; }
[ -z "$SPEC" ] || [ -f "$SPEC" ] || { echo "oracle.sh: spec file not found: $SPEC" >&2; exit 2; }

WT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "oracle.sh: run it from the worktree (this is not a git repository)" >&2; exit 2; }
GITDIR="$(git rev-parse --git-dir)"; GITDIR="$(cd "$GITDIR" && pwd)"
CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
if [ ! -f "$CFG" ]; then CFG="$(mktemp)"; trap 'rm -f "$CFG"' EXIT; merged_config . > "$CFG" 2>/dev/null || echo '{}' > "$CFG"; fi

ocfg() {  # <key> <default> → the value of settings.oracle.<key>, or the default
  jq -r --arg k "$1" --arg d "$2" '(.settings.oracle? | objects | .[$k]?) // $d | tostring' "$CFG" 2>/dev/null || printf '%s' "$2"
}
num() {  # <name> <value> <default> → the value if it is a non-negative number, else the default (with a warning)
  case "$2" in ''|*[!0-9.]*|*.*.*|.) echo "oracle.sh: settings.oracle.$1 must be a non-negative number (got '$2'); using $3" >&2; printf '%s' "$3";; *) printf '%s' "$2";; esac
}
[ "$(jq -r '(.settings.oracle? | objects | .enabled?) == true' "$CFG" 2>/dev/null)" = true ] \
  || echo "oracle.sh: note: settings.oracle.enabled is not true, so the Planner does not use the oracle in this workspace; running it anyway." >&2
MAXLOAD="$(num maxLoad "$(ocfg maxLoad 0.8)" 0.8)"; WAITMAX="$(num waitMax "$(ocfg waitMax 300)" 300)"
TIMEOUT="$(num timeout "$(ocfg timeout 600)" 600)"; RETRIES="$(num retries "$(ocfg retries 1)" 1)"
WAITMAX="${WAITMAX%%.*}"; TIMEOUT="${TIMEOUT%%.*}"; RETRIES="${RETRIES%%.*}"   # integers for the python side

ARGS=(--worktree "$WT" --max-load "$MAXLOAD" --wait-max "${WAITMAX:-300}" --timeout "${TIMEOUT:-600}" --retries "${RETRIES:-1}")
if [ -n "$SPEC" ]; then ARGS+=(--spec-file "$SPEC" --task "$TASK"); else ARGS+=(--task "$TASK"); fi
[ -z "$BASE" ] || ARGS+=(--base "$BASE")
# What Dev last ran, from the last dev line of the provenance file written by agent.sh
if [ -f "$GITDIR/orca-roles.provenance.jsonl" ]; then
  P="$(jq -r 'select(.role == "dev") | "\(.agent // "")\t\(.model // "")"' "$GITDIR/orca-roles.provenance.jsonl" 2>/dev/null | tail -1)"
  if [ -n "$P" ]; then
    A="${P%%$'\t'*}"; M="${P#*$'\t'}"
    [ -z "$A" ] || ARGS+=(--agent "$A")
    [ -z "$M" ] || ARGS+=(--model "$M")
  fi
fi
S="$(shasum "$CFG" 2>/dev/null | cut -d' ' -f1)"; [ -z "$S" ] || ARGS+=(--config-sha "$S")

PYTHONDONTWRITEBYTECODE=1 "$PY" "$KIT/bin/oracle/verify_task.py" "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
