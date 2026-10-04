#!/usr/bin/env bash
# Opens the tabs of the worktree's enabled roles and starts their kickoff in the background.
# Usage: launch.sh [id:<worktree>] [exceptions]
#   --only a,b       only those roles (the planner always runs)
#   --enable a,b     enables roles disabled in the configuration
#   --disable a,b    disables roles
#   --set path=value any configuration key (e.g. roles.dev.model=claude-opus-5-5, settings.jiraHandoff=false)
#   --reset          forgets this worktree's saved exceptions
# The exceptions go on the project's setup script line and are applied on top of config.json and .orca-roles.json.
# They are saved per worktree, so 'roles' without options applies them again when resuming.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,10p "$0"; exit 0;; esac
command -v jq >/dev/null || { echo "ERROR: 'jq' is missing (macOS: brew install jq; Ubuntu: sudo apt install jq); orca-roles cannot read its configuration without it." >&2; exit 1; }
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
command -v orca >/dev/null || { echo "ERROR: Orca CLI not found (neither 'orca' nor \$ORCA_CLI_COMMAND). Run this from an Orca terminal." >&2; exit 1; }
WT=""; RESET=0; FLAGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) RESET=1;;
    --only|--enable|--disable|--set) FLAGS+=("$1" "${2:-}"); shift;;
    -*) FLAGS+=("$1");;
    *) WT="$1";;
  esac
  shift
done
WT="${WT:-${ORCA_WORKTREE_ID:+id:$ORCA_WORKTREE_ID}}"; WT="${WT:-active}"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
OVR="$GITDIR/orca-roles.overrides.json"  # this worktree's exceptions
STATE="$GITDIR/orca-roles.env"
CFG="$GITDIR/orca-roles.config.json"     # copy of the effective config for this worktree
LOG="$GITDIR/orca-roles-launch.log"
exec > >(tee -a "$LOG") 2>&1
echo "== $(date '+%F %T') launch.sh in $WT"

merged_config . > "$CFG" || { echo "ERROR: invalid configuration (check ~/.orca-roles/config.json and .orca-roles.json)"; exit 1; }
[ "$RESET" = 1 ] && rm -f "$OVR" && echo "This worktree's exceptions were forgotten."
if [ ${#FLAGS[@]} -gt 0 ]; then
  NEWOVR="$(overrides_from_args "${FLAGS[@]}")" || exit 1
  printf '%s\n' "$NEWOVR" > "$OVR.tmp"
  ERR="$(check_overrides "$CFG" "$OVR.tmp")"
  [ -z "$ERR" ] || { rm -f "$OVR.tmp"; echo "$ERR"; exit 1; }
  mv "$OVR.tmp" "$OVR"
elif [ -f "$OVR" ]; then
  echo "Applying this worktree's saved exceptions ($OVR)."
fi
if [ -f "$OVR" ]; then
  echo "Exceptions: $(jq -c '{only, enable, disable, set: [.set[] | "\(.path | join(".")): \(.value | tojson)"]} | with_entries(select(.value | length > 0))' "$OVR")"
  apply_overrides "$CFG" "$OVR" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG" || { echo "ERROR: could not apply the exceptions in $OVR"; exit 1; }
fi

FRESH=0; [ -s "$STATE" ] || FRESH=1     # first launch in this worktree (not a resume)
# Whether a role's tab is still working: 0 alive, 1 no tab, 2 the tab exists but its agent is gone (e.g. after Ctrl+C),
# 3 its tab was closed with the X but Orca kept the session running without a tab ("orphaned").
# Orca reports the agent of a tab in agentIdentity for the agents it knows (claude, codex); for custom agents only the tab counts.
# An agent that is still starting has no identity for a moment, so it is checked a few times before giving up.
agent_in()   { orca terminal show --terminal "$1" --json 2>/dev/null | jq -r '[.. | objects | select(has("agentIdentity")) | .agentIdentity // empty] | first // empty' 2>/dev/null; }
role_alive() {  # role_alive <role> <handle>
  [ -n "${2:-}" ] || return 1
  local js; js="$(orca terminal show --terminal "$2" --json 2>/dev/null)" || return 1
  printf '%s' "$js" | jq -e '[.. | objects | select(has("orphaned")) | .orphaned] | first == true' >/dev/null 2>&1 && return 3
  case "$(rstr "$CFG" "$1" agent)" in claude|codex|"") ;; *) return 0;; esac
  local i; for i in $(seq 1 "${ORCA_ROLES_AGENT_CHECKS:-5}"); do
    [ -n "$(agent_in "$2")" ] && return 0
    [ "$i" -lt "${ORCA_ROLES_AGENT_CHECKS:-5}" ] && sleep 2
  done
  return 2
}
handle_of() { jq -r '[.. | .handle? // empty] | first // empty'; }

WAIT="$(setting "$CFG" launchWaitSeconds 15)"
LIST=""
for i in $(seq 1 "$WAIT"); do
  LIST="$(orca terminal list --worktree "$WT" --json 2>/dev/null)" && break
  echo "Waiting for Orca to have the worktree ready ($i/$WAIT)..."; sleep 1
done
# Terminals that existed before the team, in a new worktree: the composer's extra session is among them, still with its first
# title (Claude Code renames it soon after). kickoff.sh uses this snapshot to recognize and close it.
PRE="$GITDIR/orca-roles.preexisting.json"; rm -f "$PRE"
[ "$FRESH" = 1 ] && [ -n "$LIST" ] && printf '%s' "$LIST" | seen_merge "" > "$PRE"
# Is Orca creating this worktree right now (so the composer's session may be open)? Orca passes ORCA_ROOT_PATH and
# ORCA_WORKTREE_PATH to its setup script, but the setup terminal it leaves open keeps them, so a 'roles' typed there has them
# too. So it also takes a worktree created moments ago: git writes the 'gitdir' file in its git dir when the worktree is added
# or moved into place, as Orca does when it creates one. Only both together, on a first launch, let the kit close tabs.
SETUPCTX="$GITDIR/orca-roles.setup-context"; rm -f "$SETUPCTX"
WT_JUST_CREATED=0; [ -f "$GITDIR/gitdir" ] && [ -n "$(find "$GITDIR/gitdir" -mmin -5 2>/dev/null)" ] && WT_JUST_CREATED=1
if [ -n "${ORCA_ROOT_PATH:-}${ORCA_WORKTREE_PATH:-}" ] && [ "$WT_JUST_CREATED" = 1 ] && [ "$FRESH" = 1 ]; then
  echo "Started by Orca's setup script on a worktree it just created."; : > "$SETUPCTX"
else
  echo "Not a worktree Orca is creating right now: tabs that existed before the team are left alone."
fi

# The agents' working folders, ignored locally
EVID="$(jq -r '.roles["visual-tester"].params.evidenceDir // "qa-evidence"' "$CFG")"
if COMMON="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  mkdir -p "$COMMON/info"; touch "$COMMON/info/exclude"
  for p in research/ "$EVID/"; do grep -qxF "$p" "$COMMON/info/exclude" || echo "$p" >> "$COMMON/info/exclude"; done
fi

# shellcheck source=/dev/null
[ -f "$STATE" ] && . "$STATE"
ROLES="$(enabled_roles "$CFG" | tr '\n' ' ')"
NEW=""; RESUMED=""   # RESUMED: roles whose previous tab died (e.g. after a restart); the Planner recovers the state
for id in $ROLES; do
  v="$(var_of "$id")"; t="$(title_of "$CFG" "$id")"
  role_alive "$id" "${!v:-}"; st=$?
  [ "$st" = 0 ] && continue
  if [ "$st" = 3 ]; then
    RESUMED="$RESUMED $id"; echo "The tab of $t (${!v}) was closed but Orca kept its session running; ending it and opening a new one."
    orca terminal close --terminal "${!v}" --json >/dev/null 2>&1 || orca terminal close --terminal "${!v}" --tab --json >/dev/null 2>&1 || true
  elif [ "$st" = 2 ]; then
    RESUMED="$RESUMED $id"; echo "The agent in the tab of $t (${!v}) is gone; closing that tab and opening a new one."
    orca terminal close --terminal "${!v}" --tab --json >/dev/null 2>&1 || true
  elif [ -n "${!v:-}" ]; then
    RESUMED="$RESUMED $id"; echo "The previous tab of $t (${!v}) no longer exists; opening a new one."
  fi
  h=""
  for try in 1 2 3; do
    h=$(orca terminal create --worktree "$WT" --title "$t" --command "ORCA_ROLES_CONFIG='$CFG' '$KIT/bin/agent.sh' $id" --json 2>&1 | handle_of)
    [ -n "$h" ] && break
    echo "Retrying $t ($try/3)..."; sleep 2
  done
  [ -n "$h" ] || { echo "ERROR: could not open $t. Check $LOG" >&2; exit 1; }
  printf -v "$v" '%s' "$h"; NEW="$NEW $id"
done

: > "$STATE"
for id in $ROLES; do v="$(var_of "$id")"; echo "$v=${!v}" >> "$STATE"; done
cat "$STATE"

if [ -z "$NEW" ]; then echo "All roles are already open."; exit 0; fi
[ -n "$RESUMED" ] && echo "Resuming workspace: the Planner will recover the previous state and give you a summary."
nohup "$KIT/bin/kickoff.sh" "$WT" "$STATE" "$CFG" "$NEW" "$RESUMED" > "$GITDIR/orca-roles-kickoff.log" 2>&1 &
echo "Role kickoff in progress (log: $GITDIR/orca-roles-kickoff.log)"
