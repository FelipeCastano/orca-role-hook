#!/usr/bin/env bash
# Switches this worktree's academic-research team to the other phase.
# Usage (from the worktree):  phase.sh <experiment|writing>
# The Planner runs it after the user confirms, once no role of the current phase has a task in flight (it closes them).
# It refuses with uncommitted changes (the phase change keeps the work in git), and going back to experiment needs STATE.md
# committed at the repository root. It closes the roles of the current phase that the target phase does not have (close-role.sh)
# and opens the target's with 'launch.sh --set settings.phase=<phase>', so the phase is saved like the worktree's other exceptions:
# 'roles --reset' forgets it and the team starts again in experiment.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,8p "$0"; exit 0;; esac
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
[ $# -eq 1 ] && { [ "$1" = experiment ] || [ "$1" = writing ]; } || { echo "phase.sh: usage: phase.sh <experiment|writing>" >&2; exit 1; }
TARGET="$1"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "$STATE or $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
MODE="$(mode_of --saved "$CFG")" || exit 1
[ "$MODE" = academic-research ] || { echo "phase.sh: only for mode academic-research (this worktree: $MODE)" >&2; exit 1; }
CURRENT="$(phase_of "$CFG")"
[ "$CURRENT" != "$TARGET" ] || { echo "Already in phase $TARGET."; exit 0; }
TOP="$(git rev-parse --show-toplevel)" || exit 1
[ -z "$(cd "$TOP" && git status --porcelain)" ] || { echo "phase.sh: the repository has uncommitted changes; commit them first (the phase change keeps the work in git). Nothing was changed." >&2; exit 1; }
if [ "$TARGET" = experiment ] && ! (cd "$TOP" && git ls-files --error-unmatch STATE.md >/dev/null 2>&1); then
  echo "phase.sh: going back to experiment needs STATE.md committed at the repository root (the writing state to resume from). Nothing was changed." >&2; exit 1
fi
TCFG="$(mktemp "${TMPDIR:-/tmp}/orca-roles-phase.XXXXXX")"; trap 'rm -f "$TCFG"' EXIT
jq --arg p "$TARGET" '.settings.phase = $p' "$CFG" > "$TCFG" || exit 1
KEEP="$(enabled_roles "$TCFG")" || exit 1
CLOSE=""
for id in $(cut -d= -f1 "$STATE" | tr 'A-Z_' 'a-z-'); do
  [ "$id" = planner ] && continue
  printf '%s\n' "$KEEP" | grep -qxF "$id" || CLOSE="$CLOSE $id"
done
if [ -n "$CLOSE" ]; then
  # shellcheck disable=SC2086
  ORCA_ROLES_PHASE_SWITCH=1 "$KIT/bin/close-role.sh" $CLOSE || { echo "phase.sh: could not close every role of phase $CURRENT; run it again." >&2; exit 1; }
fi
"$KIT/bin/launch.sh" --set "settings.phase=$TARGET" || { echo "phase.sh: the roles of phase $CURRENT were closed but opening phase $TARGET failed (see above); run roles to open them. If roles --status still shows phase $CURRENT, run phase.sh $TARGET again." >&2; exit 1; }
cat "$STATE"
echo "Phase: $TARGET."
