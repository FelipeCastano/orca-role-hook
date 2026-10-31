#!/usr/bin/env bash
# Compacts the conversation of a Claude role (/compact) instead of clearing it; it sends no role message.
# Usage (from the worktree):  compact-role.sh <role> [--instructions "<text>"]
# The local coordinator runs it as `compact-role.sh planner` right before giving the Planner its next task.
# It refuses the local coordinator, and is never run on a role with a task in flight (the caller ensures that). A role whose agent is not
# claude is cleaned with clean.sh instead (its own waits), and the exit status is clean.sh's.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "compact-role.sh: $STATE or $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
ROLE="${1:-}"; INSTR=""
[ -n "$ROLE" ] || { sed -n 2,3p "$0" >&2; exit 2; }
shift
case "${1:-}" in
  "") ;;
  --instructions) [ $# -eq 2 ] || { echo "compact-role.sh: --instructions takes one text." >&2; exit 2; }; INSTR="$2";;
  *) echo "compact-role.sh: unexpected argument: $1" >&2; exit 2;;
esac
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
TIMEOUT_MS=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))
orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null \
  || { echo "compact-role.sh: timed out waiting for $ROLE ($h) to be idle before compacting; nothing was sent." >&2; exit 1; }
orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1; pace 1
orca terminal send --terminal "$h" --text "/compact${INSTR:+ $INSTR}" --enter --json >/dev/null \
  || { echo "compact-role.sh: could not send /compact to $ROLE ($h)." >&2; exit 1; }
orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null \
  || { echo "compact-role.sh: timed out waiting for $ROLE ($h) to finish compacting." >&2; exit 1; }
echo "compacted $ROLE ($h)"
