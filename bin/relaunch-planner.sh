#!/usr/bin/env bash
# Reopens the Planner of this worktree's team with the kit's settings and its conversation, once the turn that ran launch.sh from the tab
# Orca restored has ended. Started detached by launch.sh (never by hand); its log is orca-roles-relaunch.log in the git dir.
# Usage: relaunch-planner.sh <worktree> <git dir> <restored tab handle> <worktree folder>
# It waits for that tab to be idle, lets it settle and runs 'launch.sh <worktree> --reopen' from the worktree folder without the
# tab's handle, so launch.sh closes the restored tab and opens the Planner again. If the Planner was busy and was not reopened, it
# tries once more; it never runs launch.sh more than twice, and changes nothing when the tab never becomes idle.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,7p "$0"; exit 0;; esac
[ $# -ge 4 ] || { sed -n 2,4p "$0" >&2; exit 1; }
WT="$1"; GITDIR="$2"; HANDLE="$3"; TOP="$4"
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
CFG="$GITDIR/orca-roles.config.json"; STATE="$GITDIR/orca-roles.env"
SECS="$(setting "$CFG" kickoffTimeoutSeconds 180 2>/dev/null)"; case "$SECS" in ''|*[!0-9]*) SECS=180;; esac
TIMEOUT_MS=$((SECS * 1000))
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
planner_handle() { grep '^PLANNER=' "$STATE" 2>/dev/null | head -1 | cut -d= -f2-; }
reopen() {  # waits for the Planner's tab to be idle, then runs the launch; 1 if the tab never became idle
  local out
  if ! out="$(orca terminal wait --terminal "$HANDLE" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json 2>&1)"; then
    log "The Planner's tab did not become idle ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)); nothing was changed."
    return 1
  fi
  sleep "${ORCA_ROLES_RELAUNCH_SETTLE:-3}"
  log "Running launch.sh --reopen in $TOP"
  env -u ORCA_TERMINAL_HANDLE ORCA_ROLES_RELAUNCH=1 "$KIT/bin/launch.sh" "$WT" --reopen 2>&1
  log "launch.sh exited with $?"
}
cd "$TOP" || { log "Cannot enter $TOP; nothing was changed."; exit 0; }
OLD="$(planner_handle)"
log "Waiting for the Planner's tab ($HANDLE) to end its turn."
reopen || exit 0
if [ -n "$OLD" ] && [ "$(planner_handle)" = "$OLD" ]; then
  log "The Planner was not reopened (its tab was busy); trying once more."
  reopen || exit 0
  [ "$(planner_handle)" != "$OLD" ] || log "The Planner was not reopened after two tries (busy, or its conversation could not be read); nothing was closed. Run roles from another terminal to reopen it."
fi
exit 0
