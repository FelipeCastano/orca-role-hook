#!/usr/bin/env bash
# Compacts the conversation of a Claude role (/compact) instead of clearing it; it sends no role message.
# Usage (from the worktree):  compact-role.sh <role> [--if-above <tokens>] [--instructions "<text>"]
# The local coordinator runs it as `compact-role.sh planner --if-above 200000 --instructions "<what to keep>"` after each Planner report.
# It refuses the local coordinator, and is never run on a role with a task in flight (the caller ensures that). A role whose agent is not
# claude is cleaned with clean.sh instead (its own waits), and the exit status is clean.sh's.
# --if-above <tokens>: compacts only when the role's current context is above <tokens> (read from its Claude Code transcript: the last
# answer's input + cache-read + cache-creation tokens); not above, or compacted since its last answer, prints why and sends nothing (exit 0);
# a size it cannot read does not compact either. Overrides for tests: ORCA_ROLES_CLAUDE_PROJECTS (Claude Code's projects folder),
# ORCA_ROLES_SESSION_HANDLES (the folder where the kit's SessionStart hook records each session's tab handle).
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "compact-role.sh: $STATE or $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
ROLE="${1:-}"; INSTR=""; ABOVE=""; above_set=0; instr_set=0
[ -n "$ROLE" ] || { sed -n 2,3p "$0" >&2; exit 2; }
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --if-above)
      [ "$above_set" = 0 ] || { echo "compact-role.sh: unexpected argument: $1" >&2; exit 2; }; above_set=1
      [ $# -ge 2 ] || { echo "compact-role.sh: --if-above takes a positive whole number of tokens." >&2; exit 2; }
      case "$2" in ''|*[!0-9]*|0*) echo "compact-role.sh: --if-above takes a positive whole number of tokens." >&2; exit 2;; esac
      ABOVE="$2"; shift;;
    --instructions)
      [ "$instr_set" = 0 ] || { echo "compact-role.sh: unexpected argument: $1" >&2; exit 2; }; instr_set=1
      [ $# -ge 2 ] || { echo "compact-role.sh: --instructions takes one text." >&2; exit 2; }
      INSTR="$2"; shift;;
    *) echo "compact-role.sh: unexpected argument: $1" >&2; exit 2;;
  esac
  shift
done
[ "$ROLE" = local-coordinator ] && { echo "compact-role.sh: the local coordinator is not compacted by the kit." >&2; exit 2; }
v="$(var_of "$ROLE")"
h="$(grep "^$v=" "$STATE" | head -1 | cut -d= -f2-)"
[ -n "$h" ] || { echo "compact-role.sh: unknown role or no handle for '$ROLE'." >&2; exit 2; }
ag="$(rstr "$CFG" "$ROLE" agent)"
if [ "${ag:-claude}" != claude ]; then
  "$KIT/bin/clean.sh" "$ROLE"; rc=$?
  [ "$rc" -ne 0 ] || echo "compact-role: $ROLE runs $ag: compacting is claude-only, cleaned it instead"
  exit "$rc"
fi
CT_JQ='
[ inputs | fromjson? | select(type == "object") ] as $L
| ([ range(0; $L | length) | select($L[.] as $e | $e.type == "assistant" and (($e.message.usage | type) == "object")
        and ($e.isApiErrorMessage != true) and ($e.message.model != "<synthetic>") and ($e.isSidechain != true)) ] | last // -1) as $ai
| ([ range(0; $L | length) | select($L[.] | .type == "system" and .subtype == "compact_boundary") ] | last // -1) as $bi
| if $ai < 0 then "unknown"
  elif $bi > $ai then "compacted"
  else ($L[$ai].message.usage | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) | tostring)
  end
'
context_tokens() {  # <handle>: prints the context in tokens, "compacted", or nothing when it cannot be read; never fails
  local h="$1" wt p sdir dir f tf sz win out
  wt="$(cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null && pwd -P)" || return 0
  p="${ORCA_ROLES_CLAUDE_PROJECTS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
  sdir="$p/$(printf '%s' "$wt" | tr '/.' '--')"
  [ -d "$sdir" ] || sdir="$p/$(printf '%s' "$wt" | tr -c 'A-Za-z0-9\n' '-')"
  [ -d "$sdir" ] || return 0
  dir="${ORCA_ROLES_SESSION_HANDLES:-$KIT/state/session-handles}"
  tf=""
  if [ -d "$dir" ]; then
    while IFS= read -r f; do
      [ -f "$dir/$f" ] && grep -qx -- "$h" "$dir/$f" 2>/dev/null || continue
      [ -f "$sdir/$f.jsonl" ] && { tf="$sdir/$f.jsonl"; break; }
    done < <(ls -t "$dir" 2>/dev/null)
  fi
  [ -n "$tf" ] || return 0
  sz="$(stat -f%z "$tf" 2>/dev/null || stat -c%s "$tf" 2>/dev/null)"
  case "$sz" in ''|*[!0-9]*) sz="$(wc -c < "$tf" 2>/dev/null | tr -d ' ')";; esac
  case "$sz" in ''|*[!0-9]*) return 0;; esac
  win=1048576
  while :; do
    if [ "$sz" -gt "$win" ]; then
      out="$(tail -c "$win" "$tf" 2>/dev/null | tail -n +2 | jq -nRr "$CT_JQ" 2>/dev/null)"
    else
      out="$(tail -c "$win" "$tf" 2>/dev/null | jq -nRr "$CT_JQ" 2>/dev/null)"
    fi
    case "$out" in ''|unknown|null) ;; *) printf '%s\n' "$out"; return 0;; esac
    case "$win" in
      1048576) win=8388608;;
      8388608) win=33554432;;
      *) return 0;;
    esac
  done
}
TIMEOUT_MS=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))
orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null \
  || { echo "compact-role.sh: timed out waiting for $ROLE ($h) to be idle before compacting; nothing was sent." >&2; exit 1; }
if [ -n "$ABOVE" ]; then
  n="$(context_tokens "$h")"
  if [ "$n" = compacted ]; then echo "compact-role: $ROLE was compacted since its last answer: not compacted"; exit 0
  elif [ -z "$n" ]; then echo "compact-role: $ROLE context size unknown: not compacted"; exit 0
  elif [ "$n" -gt "$ABOVE" ]; then echo "compact-role: $ROLE context $n tokens, above $ABOVE: compacting"
  else echo "compact-role: $ROLE context $n tokens, at most $ABOVE: not compacted"; exit 0; fi
fi
orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1; pace 1
orca terminal send --terminal "$h" --text "/compact${INSTR:+ $INSTR}" --enter --json >/dev/null \
  || { echo "compact-role.sh: could not send /compact to $ROLE ($h)." >&2; exit 1; }
orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null \
  || { echo "compact-role.sh: timed out waiting for $ROLE ($h) to finish compacting." >&2; exit 1; }
echo "compacted $ROLE ($h)"
