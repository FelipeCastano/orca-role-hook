#!/usr/bin/env bash
# Cleans the context of one or more workers: opens a new conversation in their agent and resends their role.
# Usage (from the worktree):  clean.sh <role|title|handle> [...]   |   clean.sh --all   |   clean.sh --msg <role>  (only prints the role message;
# for the Planner, the one for after its conversation was cleared: see role_anchor, which tells each role to ask for it)
# The local coordinator runs it after the user confirms. It never cleans the front role (the local coordinator) or a worker with a task in
# flight (the local coordinator ensures that). The Planner is a worker and can be cleaned.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
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
  if [ "$id" = local-coordinator ] && [ ! -e "$GITDIR/orca-roles.mode-pending" ]; then
    wt="${ORCA_WORKTREE_ID:+id:$ORCA_WORKTREE_ID}"; { IFS= read -r key; IFS= read -r url; } < <(worktree_jira "${wt:-active}" "$CFG")
    if [ -e "$GITDIR/orca-roles.mode-pending" ]; then planner_ask_msg "$CFG"
    else planner_msg "$CFG" "$(echo $IDS)" "$STATE" "$key" "$url" 3; fi
  elif [ "$id" = local-coordinator ]; then planner_ask_msg "$CFG"
  else worker_msg "$CFG" "$id"; fi
  echo; exit 0
fi
TARGETS=()
if [ "$1" = --all ]; then
  for id in $IDS; do
    [ "$id" = local-coordinator ] && continue
    TARGETS+=("$id")
  done
else
  for x in "$@"; do id="$(resolve "$x")"; [ -n "$id" ] || { echo "There is no worker '$x' in this workspace. Roles: $(echo $IDS)" >&2; exit 1; }; TARGETS+=("$id"); done
fi

[ ${#TARGETS[@]} -gt 0 ] || { echo "There are no workers to clean in this workspace."; exit 0; }
RC=0
for id in "${TARGETS[@]}"; do
  t="$(title_of "$CFG" "$id")"
  [ "$id" = local-coordinator ] && { echo "$t: the local coordinator does not clean itself."; RC=1; continue; }
  v="$(var_of "$id")"; h="${!v}"
  orca terminal show --terminal "$h" --json >/dev/null 2>&1 || { echo "$t: its tab ($h) does not respond."; RC=1; continue; }
  cmd="$(clear_command "$CFG" "$id")"
  [ -n "$cmd" ] || { echo "$t: its agent has no cleanup command; define 'clearCommand' in its role in config.json."; RC=1; continue; }
  ocf=""; [ "$(rstr "$CFG" "$id" agent)" = opencode ] && { ocf="$(oc_session_file "$id" "$GITDIR")" && [ -f "$ocf" ] || ocf=""; }
  since=$(( $(date +%s) * 1000 ))   # OpenCode: /new makes the tab switch to a session created after this moment
  orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1; pace 1
  orca terminal send --terminal "$h" --text "$cmd" --enter --json >/dev/null || { echo "$t: could not send $cmd."; RC=1; continue; }
  orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
  if orca terminal send --terminal "$h" --text "$(worker_msg "$CFG" "$id")" --enter --json >/dev/null; then
    echo "$t: context cleaned ($cmd) and role resent."
    [ "$id" = planner ] && { orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true; }
    # OpenCode: /new left the tab in a session whose id the kit did not choose; track it and delete the old one (it was idle)
    if [ -n "$ocf" ]; then
      orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
      oc_retrack "$id" "$since" "$GITDIR"
    fi
  else
    echo "$t: context cleaned, but the role could not be resent. Resend it with: orca terminal send --terminal $h --text \"\$($(kit_env)$KIT/bin/clean.sh --msg $id)\" --enter"; RC=1
  fi
done
exit $RC
