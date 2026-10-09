#!/usr/bin/env bash
# Cleans the context of one or more workers: opens a new conversation in their agent and resends their role.
# Usage (from the worktree):  clean.sh <role|title|handle> [...]   |   clean.sh --all   |   clean.sh --msg <role>  (only prints the role message;
# for the Planner, the one for after its conversation was cleared: each claude role is told in its system prompt to ask for it)
# The Planner runs it after the user confirms. It never cleans the Planner or a worker with a task in flight (the Planner ensures that).
set -uo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "$STATE or $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
[ $# -gt 0 ] || { sed -n 2,3p "$0" >&2; exit 1; }
# shellcheck source=/dev/null
. "$STATE"
TIMEOUT_MS=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))
IDS="$(cut -d= -f1 "$STATE" | tr 'A-Z_' 'a-z-')"
lower() { tr 'A-Z' 'a-z'; }

resolve() {  # <role|title|handle> → role id
  local x="$1" id v
  for id in $IDS; do
    v="$(var_of "$id")"
    if [ "$x" = "$id" ] || [ "$(echo "$x" | lower)" = "$(title_of "$CFG" "$id" | lower)" ] || [ "$x" = "${!v}" ]; then echo "$id"; return; fi
  done
}

if [ "$1" = --msg ]; then
  id="$(resolve "${2:-}")"; [ -n "$id" ] || { echo "Unknown role: ${2:-}" >&2; exit 1; }
  if [ "$id" = planner ]; then
    wt="${ORCA_WORKTREE_ID:+id:$ORCA_WORKTREE_ID}"; { IFS= read -r key; IFS= read -r url; } < <(worktree_jira "${wt:-active}" "$CFG")
    planner_msg "$CFG" "$(echo $IDS)" "$STATE" "$key" "$url" 3
  else worker_msg "$CFG" "$id"; fi
  echo; exit 0
fi
TARGETS=()
if [ "$1" = --all ]; then
  for id in $IDS; do [ "$id" = planner ] || TARGETS+=("$id"); done
else
  for x in "$@"; do id="$(resolve "$x")"; [ -n "$id" ] || { echo "There is no worker '$x' in this workspace. Roles: $(echo $IDS)" >&2; exit 1; }; TARGETS+=("$id"); done
fi

[ ${#TARGETS[@]} -gt 0 ] || { echo "There are no workers to clean in this workspace."; exit 0; }
RC=0
for id in "${TARGETS[@]}"; do
  t="$(title_of "$CFG" "$id")"
  [ "$id" = planner ] && { echo "$t: the Planner does not clean itself."; RC=1; continue; }
  v="$(var_of "$id")"; h="${!v}"
  orca terminal show --terminal "$h" --json >/dev/null 2>&1 || { echo "$t: its tab ($h) does not respond."; RC=1; continue; }
  cmd="$(clear_command "$CFG" "$id")"
  [ -n "$cmd" ] || { echo "$t: its agent has no cleanup command; define 'clearCommand' in its role in config.json."; RC=1; continue; }
  orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1; sleep 1
  orca terminal send --terminal "$h" --text "$cmd" --enter --json >/dev/null || { echo "$t: could not send $cmd."; RC=1; continue; }
  orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
  if orca terminal send --terminal "$h" --text "$(worker_msg "$CFG" "$id")" --enter --json >/dev/null; then
    echo "$t: context cleaned ($cmd) and role resent."
  else
    echo "$t: context cleaned, but the role could not be resent. Resend it with: orca terminal send --terminal $h --text \"\$($KIT/bin/clean.sh --msg $id)\" --enter"; RC=1
  fi
done
exit $RC
