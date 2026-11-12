#!/usr/bin/env bash
# Closes the tab of one or more roles in this workspace and forgets their handle (the opposite of what launch.sh does).
# Usage (from the worktree):  close-role.sh <role|title|handle> [...]
# The local coordinator runs it after the user confirms (for a role opened per task, without asking, after its report), once the role has no task in flight. It never closes the local coordinator;
# the Planner is a worker and can be closed. An instance (`<role>-<n>`) is closed the same way and forgotten by the configuration.
# It does not change the configuration: if the role is still enabled and opens at start, 'roles' would open it again; a role that opens on first use or per task opens again with 'roles --open <id>' (see the message it prints).
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "$STATE or $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
[ $# -gt 0 ] || { sed -n 2,5p "$0" >&2; exit 1; }
# shellcheck source=/dev/null
. "$STATE"
IDS="$(cut -d= -f1 "$STATE" | tr 'A-Z_' 'a-z-')"
lower() { tr 'A-Z' 'a-z'; }
resolve() {  # <role|title|handle> → role id
  local x="$1" id v
  for id in $IDS; do
    v="$(var_of "$id")"
    if [ "$x" = "$id" ] || [ "$(echo "$x" | lower)" = "$(title_of "$CFG" "$id" | lower)" ] || [ "$x" = "${!v}" ]; then echo "$id"; return; fi
  done
}

RC=0
for x in "$@"; do
  id="$(resolve "$x")"
  [ -n "$id" ] || { echo "There is no role '$x' open in this workspace. Roles: $(echo $IDS)" >&2; RC=1; continue; }
  t="$(title_of "$CFG" "$id")"
  [ "$id" = local-coordinator ] && { echo "$t: the local coordinator is never closed."; RC=1; continue; }
  v="$(var_of "$id")"; h="${!v}"
  js=""; src=1
  if [ -n "$h" ]; then js="$(orca terminal show --terminal "$h" --json 2>/dev/null)"; src=$?; fi
  if [ -n "$h" ] && [ "$src" -ne 0 ] && [ "$(printf '%s' "$js" | jq -r '.error.code // empty' 2>/dev/null)" != terminal_handle_stale ]; then
    echo "$t: Orca did not answer about its tab ($h); nothing was changed."; RC=1; continue
  fi
  # An OpenCode role's session stays in OpenCode's store after its tab is gone: delete it first (closing the tab ends its turn)
  [ "$(rstr "$CFG" "$id" agent)" = opencode ] && oc_session_delete "$id" "$GITDIR"
  if [ "$src" -eq 0 ]; then
    if printf '%s' "$js" | jq -e '[.. | objects | select(has("orphaned")) | .orphaned] | first == true' >/dev/null 2>&1; then
      # a session Orca keeps without a tab (orphaned) is ended like launch.sh does: the plain close first, --tab only when that fails
      orca terminal close --terminal "$h" --json >/dev/null 2>&1; crc=$?
      [ "$crc" = 0 ] || [ "$crc" = 124 ] || { orca terminal close --terminal "$h" --tab --json >/dev/null 2>&1; crc=$?; }
    else
      orca terminal close --terminal "$h" --tab --json >/dev/null 2>&1; crc=$?
    fi
    if [ "$crc" = 124 ]; then close_unconfirmed "$h" "$t" || { echo "$t: could not close its tab ($h)."; RC=1; continue; }
    elif [ "$crc" != 0 ]; then echo "$t: could not close its tab ($h)."; RC=1; continue; fi
    echo "$t: tab closed ($h)."
  else
    echo "$t: its tab ($h) was already gone."
  fi
  TMPS="$(mktemp)"; grep -v "^$v=" "$STATE" > "$TMPS" || true; cat "$TMPS" > "$STATE"; rm -f "$TMPS"
  PTYF="$(dirname "$STATE")/orca-roles.pty"; [ -f "$PTYF" ] && { grep -v "^$v=" "$PTYF" > "$PTYF.tmp" || true; mv "$PTYF.tmp" "$PTYF"; }
  TABSF="$(dirname "$STATE")/orca-roles.tabs"; [ -f "$TABSF" ] && { grep -v "^$v=" "$TABSF" > "$TABSF.tmp" || true; mv "$TABSF.tmp" "$TABSF"; }
  TREESF="$(dirname "$STATE")/orca-roles.trees"; [ -f "$TREESF" ] && { grep -v "^$v=" "$TREESF" > "$TREESF.tmp" || true; mv "$TREESF.tmp" "$TREESF"; }
  ocj="$(oc_config_file "$id" "$GITDIR")" && rm -f "$ocj"   # the role's OpenCode configuration goes with its tab (agent.sh writes it again at the next start)
  rm -f "$GITDIR/orca-roles-mcp-$id.json"                    # so does its MCP file
  b="$(instance_base "$CFG" "$id")"
  if [ -n "$b" ]; then
    TMPC="$(mktemp "$CFG.XXXXXX")"
    if jq --arg i "$id" 'del(.roles[$i])' "$CFG" > "$TMPC" 2>/dev/null; then cat "$TMPC" > "$CFG"; rm -f "$TMPC"; else rm -f "$TMPC"; echo "$t: its entry stayed in the worktree's configuration; the next launch drops it."; fi
    echo "$t: instance closed; launch.sh --add $b opens a new one when needed."; continue
  fi
  [ "${ORCA_ROLES_PHASE_SWITCH:-}" = 1 ] && continue   # phase.sh closes roles that the other phase simply does not have: the hint would be wrong
  [ "${ORCA_ROLES_ROLE_RELAUNCH:-}" = 1 ] && continue   # relaunch-role.sh reopens the role itself and prints the outcome: the hint would be wrong
  om="$(open_of "$CFG" "$id")"
  if [ "$om" = hidden ]; then echo "$t: it has no tab from now on (\"open\": \"hidden\"); the local coordinator runs it with hidden-role.sh."; continue; fi
  if [ "$om" != start ]; then echo "$t: it opens again before its next task (\"open\": \"$om\")."; continue; fi
  if merged_config . 2>/dev/null | jq -e --arg r "$id" '.roles[$r] and .roles[$r].enabled != false' >/dev/null 2>&1; then
    echo "$t: still enabled in the configuration, so 'roles' would open it again. Disable it (\"enabled\": false, or --disable $id in the setup script), or remove a role you created with: ~/.orca-roles/bin/new-role.sh --remove $id"
  fi
done
exit $RC
