#!/usr/bin/env bash
# Reopens the front role (the local coordinator in programmer mode, the Planner in the others) of this worktree's team with the kit's settings and its conversation, once the turn that ran launch.sh from the tab
# Orca restored has ended. Started detached by launch.sh (never by hand); its log is orca-roles-relaunch.log in the git dir.
# Usage: relaunch-planner.sh <worktree> <git dir> <restored tab handle> <worktree folder>
# It waits for that tab to be idle, lets it settle and runs 'launch.sh <worktree> --reopen' from the worktree folder without the
# tab's handle, so launch.sh closes the restored tab and opens the front role again. If it was busy and was not reopened, it
# tries once more; it never runs launch.sh more than twice, and changes nothing when the tab never becomes idle.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,7p "$0"; exit 0;; esac
[ $# -ge 4 ] || { sed -n 2,4p "$0" >&2; exit 1; }
WT="$1"; GITDIR="$2"; HANDLE="$3"; TOP="$4"
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
CFG="$GITDIR/orca-roles.config.json"; STATE="$GITDIR/orca-roles.env"
FRONT="$(front_of "$CFG" "$GITDIR")"; FRONTV="$(var_of "$FRONT")"
SECS="$(setting "$CFG" kickoffTimeoutSeconds 180 2>/dev/null)"; case "$SECS" in ''|*[!0-9]*) SECS=180;; esac
TIMEOUT_MS=$((SECS * 1000))
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
front_handle() { grep "^$FRONTV=" "$STATE" 2>/dev/null | head -1 | cut -d= -f2-; }
reopen() {  # waits for the front role's tab to be idle, then runs the launch; 1 if the tab never became idle
  local out
  if ! out="$(orca terminal wait --terminal "$HANDLE" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json 2>&1)"; then
    log "The front role's ($FRONT) tab did not become idle ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)); nothing was changed."
    return 1
  fi
  sleep "${ORCA_ROLES_RELAUNCH_SETTLE:-3}"
  log "Running launch.sh --reopen in $TOP"
  env -u ORCA_TERMINAL_HANDLE ORCA_ROLES_RELAUNCH=1 "$KIT/bin/launch.sh" "$WT" --reopen 2>&1
  log "launch.sh exited with $?"
}
cd "$TOP" || { log "Cannot enter $TOP; nothing was changed."; exit 0; }
OLD="$(front_handle)"
log "Waiting for the front role's ($FRONT) tab ($HANDLE) to end its turn."
reopen || exit 0
if [ -n "$OLD" ] && [ "$(front_handle)" = "$OLD" ]; then
  log "The front role ($FRONT) was not reopened (its tab was busy); trying once more."
  reopen || exit 0
  [ "$(front_handle)" != "$OLD" ] || log "The front role ($FRONT) was not reopened after two tries (busy, or its conversation could not be read); nothing was closed. Run roles from another terminal to reopen it."
fi
exit 0
