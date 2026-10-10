#!/usr/bin/env bash
# Relaunches one role of this worktree's team with another model.
# Usage (from the worktree):  relaunch-role.sh <role|title> --model <model> [--no-check]
# Unless --no-check, it first tests the model with 'models.sh <role> --check --model <model>' and changes nothing if it is not "ok".
# Then it closes the role's tab (close-role.sh) and runs 'launch.sh --set roles.<id>.model=<model>': the worktree's other saved
# exceptions are kept; launch.sh reopens every tab of the team that is missing (normally just this role's), and kicks only the roles it opened
# (the role's kickoff checks the model again).
# The model is saved in the worktree's exceptions ('roles --reset' forgets it). The Planner cannot be relaunched.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,8p "$0"; exit 0;; esac
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
ROLEARG=""; MODEL=""; CHECK=1
while [ $# -gt 0 ]; do
  case "$1" in
    --model) [ -n "${2:-}" ] || { echo "relaunch-role.sh: --model needs a value" >&2; exit 1; }; MODEL="$2"; shift;;
    --no-check) CHECK=0;;
    -*) echo "relaunch-role.sh: unknown option $1" >&2; exit 1;;
    *) [ -z "$ROLEARG" ] && ROLEARG="$1" || { echo "relaunch-role.sh: only one role at a time" >&2; exit 1; };;
  esac
  shift
done
[ -n "$ROLEARG" ] || { sed -n 2,3p "$0" >&2; exit 1; }
[ -n "$MODEL" ] || { echo "relaunch-role.sh: --model <model> is required" >&2; exit 1; }
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "$STATE or $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
ID="$(resolve_role "$CFG" "$ROLEARG")"
[ -n "$ID" ] || { echo "Unknown role: $ROLEARG" >&2; exit 1; }
[ "$ID" != planner ] || { echo "The Planner cannot be relaunched from inside the team." >&2; exit 1; }
V="$(var_of "$ID")"; TITLE="$(title_of "$CFG" "$ID")"
grep -q "^$V=." "$STATE" || { echo "$ID is not open in this worktree; run roles." >&2; exit 1; }
if [ "$CHECK" = 1 ]; then
  RES="$("$KIT/bin/models.sh" "$ID" --check --model "$MODEL" 2>/dev/null | head -1)"
  case "$(printf '%s' "$RES" | cut -f2)" in
    ok) ;;
    unavailable) echo "Model $MODEL is not available for $ID; nothing was changed." >&2; exit 1;;
    *) echo "Could not check model $MODEL ($(printf '%s' "$RES" | cut -f3)); use --no-check to relaunch anyway" >&2; exit 1;;
  esac
fi
"$KIT/bin/close-role.sh" "$ID" || { echo "Could not close the tab of $TITLE; nothing was relaunched." >&2; exit 1; }
if ! "$KIT/bin/launch.sh" --set "roles.$ID.model=$MODEL"; then
  echo "Its tab was closed but relaunching failed; run roles to reopen it." >&2; exit 1
fi
grep "^$V=" "$STATE"
echo "Relaunched $TITLE on $MODEL; this worktree keeps that model (roles --reset forgets it)."
