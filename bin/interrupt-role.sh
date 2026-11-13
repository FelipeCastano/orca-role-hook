#!/usr/bin/env bash
# Stops the current turn of a Claude role (one Escape, as Claude Code's Esc) and waits until its turn has ended; the tab and its conversation stay.
# Usage (from the worktree):  interrupt-role.sh <role>
# The local coordinator runs it when the user changes the scope while the Planner works on a plan, after worker-abandon of that dispatch.
# It refuses the local coordinator and roles that are not claude; it sends nothing when the composer holds pasted text (Esc would send it).
# Exit: 0 stopped; 1 the tab does not respond, holds pasted text, or did not stop within 30 s; 2 usage or refused.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "interrupt-role.sh: $STATE or $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
ROLE="${1:-}"
case "$ROLE" in -h|--help) sed -n 2,6p "$0"; exit 0;; esac
[ $# -eq 1 ] || { sed -n 3p "$0" >&2; exit 2; }
[ -n "$ROLE" ] || { sed -n 3p "$0" >&2; exit 2; }
[ "$ROLE" = local-coordinator ] && { echo "interrupt-role.sh: the local coordinator is not interrupted by the kit." >&2; exit 2; }
v="$(var_of "$ROLE")"
h="$(grep "^$v=" "$STATE" | head -1 | cut -d= -f2-)"
[ -n "$h" ] || { echo "interrupt-role.sh: unknown role or no handle for '$ROLE'." >&2; exit 2; }
ag="$(rstr "$CFG" "$ROLE" agent)"
[ -z "$ag" ] || [ "$ag" = claude ] || { echo "interrupt-role.sh: $ROLE runs $ag: only Claude tabs are interrupted; close it with close-role.sh to end its turn." >&2; exit 2; }
js="$(orca terminal show --terminal "$h" --json 2>/dev/null)" \
  || { echo "interrupt-role.sh: $ROLE's tab ($h) does not respond; nothing was sent." >&2; exit 1; }
printf '%s' "$js" | jq -e '.result.terminal.preview // "" | contains("[Pasted text")' >/dev/null 2>&1 \
  && { echo "interrupt-role.sh: $ROLE's composer holds pasted text; nothing was sent." >&2; exit 1; }
orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1; pace 1
orca terminal wait --terminal "$h" --for tui-idle --timeout-ms 30000 --json >/dev/null \
  || { echo "interrupt-role.sh: $ROLE ($h) did not stop within 30 s; do not dispatch to it." >&2; exit 1; }
echo "interrupt-role: $ROLE ($h) stopped"
