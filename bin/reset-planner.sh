#!/usr/bin/env bash
# Resets the Planner's context the way settings.flow.plannerReset says (read from the worktree's saved config when it runs):
# "clear" (default) runs clean.sh planner, "compact" runs compact-role.sh planner. Programmer mode only.
# Usage (from the worktree):  reset-planner.sh
# The local coordinator runs it after the user confirms and the Planner has no task in flight.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$CFG" ] || { echo "reset-planner.sh: $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
[ "$(mode_of --saved "$CFG" 2>/dev/null)" = programmer ] || { echo "reset-planner.sh is for programmer mode" >&2; exit 2; }
err="$(check_config "$CFG" | grep 'settings\.flow\.plannerReset')"
[ -z "$err" ] || { echo "$err"; exit 1; }
how="$(planner_reset "$CFG")"
echo "reset-planner: $how planner"
if [ "$how" = compact ]; then "$KIT/bin/compact-role.sh" planner; else "$KIT/bin/clean.sh" planner; fi
