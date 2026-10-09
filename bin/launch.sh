#!/usr/bin/env bash
# Opens the tabs of the worktree's enabled roles and starts their kickoff in the background.
# Usage: launch.sh [id:<worktree>] [exceptions]
#   --only a,b       only those roles (the planner always runs)
#   --enable a,b     enables roles disabled in the configuration
#   --disable a,b    disables roles
#   --set path=value any configuration key (e.g. roles.dev.model=claude-opus-5-5, settings.jiraHandoff=false)
#   --mode <mode>    the team's mode (programmer, pr-reviewer, academic-writer); beats .orca-roles.json and settings.mode;
#                    saved, and kept when later options omit it
#   --reset          forgets this worktree's saved exceptions
# The exceptions go on the project's setup script line and are applied on top of config.json and .orca-roles.json.
# They are saved per worktree, so 'roles' without options applies them again when resuming.
# The mode of a worktree cannot change while its team is open: close the team first (close-role.sh, or its tabs).
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,13p "$0"; exit 0;; esac
command -v jq >/dev/null || { echo "ERROR: 'jq' is missing (macOS: brew install jq; Ubuntu: sudo apt install jq); orca-roles cannot read its configuration without it." >&2; exit 1; }
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
command -v orca >/dev/null || { echo "ERROR: Orca CLI not found (neither 'orca' nor \$ORCA_CLI_COMMAND). Run this from an Orca terminal." >&2; exit 1; }
WT=""; RESET=0; FLAGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) RESET=1;;
    --only|--enable|--disable|--set|--mode) FLAGS+=("$1" "${2:-}"); shift;;
    -*) FLAGS+=("$1");;
    *) WT="$1";;
  esac
  shift
done
WT="${WT:-${ORCA_WORKTREE_ID:+id:$ORCA_WORKTREE_ID}}"; WT="${WT:-active}"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
OVR="$GITDIR/orca-roles.overrides.json"  # this worktree's exceptions
STATE="$GITDIR/orca-roles.env"
PTY="$GITDIR/orca-roles.pty"             # each role's ptyId: stable across restarts, unlike the handle (see restored_handle)
KICKOFF="${ORCA_ROLES_KICKOFF:-$KIT/bin/kickoff.sh}"
CFG="$GITDIR/orca-roles.config.json"     # copy of the effective config for this worktree
LOG="$GITDIR/orca-roles-launch.log"
exec > >(tee -a "$LOG") 2>&1
echo "== $(date '+%F %T') launch.sh in $WT"

# The new configuration and exceptions are prepared aside and only replace the saved ones once every check has passed
NEWCFG="$CFG.new"; NEWOVR="$OVR.tmp"; OVRSRC=""
fail() { rm -f "$NEWCFG" "$NEWCFG.tmp" "$NEWOVR" "$NEWOVR.x"; echo "$1"; exit 1; }
merged_config . > "$NEWCFG" || fail "ERROR: invalid configuration (check ~/.orca-roles/config.json and .orca-roles.json)"
PREV_MODE=""; [ -f "$CFG" ] && PREV_MODE="$(jq -r '.settings.mode // "programmer"' "$CFG" 2>/dev/null)"   # the mode of the last launch
if [ ${#FLAGS[@]} -gt 0 ]; then
  overrides_from_args "${FLAGS[@]}" > "$NEWOVR" || { rm -f "$NEWCFG" "$NEWOVR"; exit 1; }
  ERR="$(check_overrides "$NEWCFG" "$NEWOVR")"
  [ -z "$ERR" ] || fail "$ERR"
  # the saved mode stays unless --mode (or --set settings.mode, which overrides_from_args turns into --mode) names another one, or --reset drops it
  if [ "$RESET" != 1 ] && [ -f "$OVR" ] && ! jq -e '.mode != null' "$NEWOVR" >/dev/null 2>&1; then
    SAVED_MODE="$(jq -c '.mode // empty' "$OVR" 2>/dev/null)"
    [ -z "$SAVED_MODE" ] || { jq -c --argjson m "$SAVED_MODE" '.mode = $m' "$NEWOVR" > "$NEWOVR.x" && mv "$NEWOVR.x" "$NEWOVR"; }
  fi
  OVRSRC="$NEWOVR"
elif [ -f "$OVR" ] && [ "$RESET" != 1 ]; then
  echo "Applying this worktree's saved exceptions ($OVR)."
  OVRSRC="$OVR"
fi
if [ -n "$OVRSRC" ]; then
  apply_overrides "$NEWCFG" "$OVRSRC" > "$NEWCFG.tmp" && mv "$NEWCFG.tmp" "$NEWCFG" || fail "ERROR: could not apply the exceptions in $OVRSRC"
fi
ERR="$(check_config "$NEWCFG" "$OVRSRC")"
[ -z "$ERR" ] || fail "$ERR"
NEWMODE="$(mode_of "$NEWCFG")"

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
pty_of_handle() { orca terminal show --terminal "$1" --json 2>/dev/null | jq -r '[.. | objects | select(has("ptyId")) | .ptyId] | first // empty' 2>/dev/null; }
saved_pty() { grep "^$1=" "$PTY" 2>/dev/null | head -1 | cut -d= -f2-; }
# After a restart (of the computer or of Orca), Orca restores the tabs that were open with NEW handles and, in each agent tab,
# relaunches the agent with 'claude --resume <session>' but without the kit's settings (model, auto mode, plugin, MCP...).
# The ptyId of a tab does not change, so the restored tab of a role is the worktree terminal whose ptyId is the saved one.
restored_handle() { printf '%s' "$LIST" | jq -r --arg p "$1" '[.. | objects | select(has("handle") and .ptyId == $p) | .handle] | first // empty' 2>/dev/null; }
# The Claude session Orca resumed in a restored tab: the 'claude' process whose ORCA_TERMINAL_HANDLE is that handle, started with --resume <id>.
session_of_handle() {
  [ -n "${ORCA_ROLES_SESSION_OF:-}" ] && { "$ORCA_ROLES_SESSION_OF" "$1"; return 0; }   # test hook
  local pid env
  for pid in $(ps -axo pid=,comm= 2>/dev/null | awk '$2 ~ /(^|\/)claude$/ {print $1}'); do
    if [ -r "/proc/$pid/environ" ]; then env="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)"; else env="$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n')"; fi
    printf '%s\n' "$env" | grep -qx "ORCA_TERMINAL_HANDLE=$1" || continue
    ps -o args= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -A1 -x -- '--resume' | tail -1 | grep -E '^[0-9a-f-]{36}$'
    return 0
  done
  return 0
}
WAIT="$(setting "$NEWCFG" launchWaitSeconds 15)"
LIST=""; LISTOK=0
for i in $(seq 1 "$WAIT"); do
  LIST="$(orca terminal list --worktree "$WT" --json 2>/dev/null)" && { LISTOK=1; break; }
  echo "Waiting for Orca to have the worktree ready ($i/$WAIT)..."; sleep 1
done
# The mode cannot change under an open team: its tabs belong to the previous mode. Any tab of the saved team that still exists counts: its saved
# handle, or, after a restart of Orca or the computer (new handles), the tab that has the role's saved ptyId.
if [ -n "$PREV_MODE" ] && [ "$PREV_MODE" != "$NEWMODE" ] && [ -s "$STATE" ]; then
  [ "$LISTOK" = 1 ] || fail "ERROR: cannot tell whether this worktree's team (mode '$PREV_MODE') is still open: 'orca terminal list' failed. Mode '$NEWMODE' was requested; nothing was changed. Try again once Orca is ready."
  for line in $(cat "$STATE"); do
    OPEN=0
    [ -n "${line#*=}" ] || continue
    role_alive "$(printf '%s' "${line%%=*}" | tr 'A-Z_' 'a-z-')" "${line#*=}"; [ $? -eq 1 ] || OPEN=1
    p="$(saved_pty "${line%%=*}")"; [ -n "$p" ] && [ -n "$(restored_handle "$p")" ] && OPEN=1
    [ "$OPEN" = 1 ] || continue
    fail "ERROR: this worktree's team is open in mode '$PREV_MODE' and mode '$NEWMODE' was requested. Close the team first (close-role.sh on each worker, or close its tabs), then run roles again. Nothing was changed."
  done
fi
# Everything checked: the new configuration and exceptions become the saved ones
jq --arg m "$NEWMODE" '.settings.mode = $m' "$NEWCFG" > "$NEWCFG.tmp" && mv "$NEWCFG.tmp" "$NEWCFG"   # the effective mode, explicit for the other scripts
mv "$NEWCFG" "$CFG"
if [ "$RESET" = 1 ]; then rm -f "$OVR"; echo "This worktree's exceptions were forgotten."; fi
[ "$OVRSRC" = "$NEWOVR" ] && mv "$NEWOVR" "$OVR"
if [ -f "$OVR" ]; then
  echo "Exceptions: $(jq -c '{only, enable, disable, mode, set: [.set[] | "\(.path | join(".")): \(.value | tojson)"]} | with_entries(select(.value | length > 0))' "$OVR")"
fi
echo "Mode: $NEWMODE"

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
EVID="$(jq -r '.roles["e2e-tester"].params.evidenceDir // "qa-evidence"' "$CFG")"
if COMMON="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  mkdir -p "$COMMON/info"; touch "$COMMON/info/exclude"
  for p in research/ "$EVID/"; do grep -qxF "$p" "$COMMON/info/exclude" || echo "$p" >> "$COMMON/info/exclude"; done
fi

# shellcheck source=/dev/null
[ -f "$STATE" ] && . "$STATE"
ROLES="$(launchable_roles "$CFG" | tr '\n' ' ')"
for id in $ROLES; do d="$(scratch_dir "$id")" && mkdir -p "$d"; done   # each role's scratch folder (outside the worktree)
for id in $ROLES; do case "$(rstr "$CFG" "$id" agent)" in claude|"") trust_folder; break;; esac; done
trust_custom_roles "$CFG" "$ROLES"   # custom agents that define how to trust the folder (role field "trust")
NEW=""; RESUMED=""; REMEMBERED=""   # RESUMED: roles reopened without memory (the Planner recovers the state); REMEMBERED: reopened with their conversation
for id in $ROLES; do
  v="$(var_of "$id")"; t="$(title_of "$CFG" "$id")"; sid=""
  role_alive "$id" "${!v:-}"; st=$?
  [ "$st" = 0 ] && continue
  if [ "$st" = 3 ]; then
    RESUMED="$RESUMED $id"; echo "The tab of $t (${!v}) was closed but Orca kept its session running; ending it and opening a new one."
    orca terminal close --terminal "${!v}" --json >/dev/null 2>&1 || orca terminal close --terminal "${!v}" --tab --json >/dev/null 2>&1 || true
  elif [ "$st" = 2 ]; then
    RESUMED="$RESUMED $id"; echo "The agent in the tab of $t (${!v}) is gone; closing that tab and opening a new one."
    orca terminal close --terminal "${!v}" --tab --json >/dev/null 2>&1 || true
  elif [ -n "${!v:-}" ]; then
    p="$(saved_pty "$v")"; rh=""; [ -n "$p" ] && rh="$(restored_handle "$p")"
    if [ -n "$rh" ]; then
      case "$(rstr "$CFG" "$id" agent)" in claude|"") sid="$(session_of_handle "$rh")";; esac
      orca terminal close --terminal "$rh" --tab --json >/dev/null 2>&1 || true
      if [ -n "$sid" ]; then
        REMEMBERED="$REMEMBERED $id"; echo "Orca restored the tab of $t after a restart ($rh) without the kit's settings; reopening it with its conversation ($sid)."
      else
        RESUMED="$RESUMED $id"; echo "Orca restored the tab of $t after a restart ($rh), but its session could not be read; closing it and opening a new one."
      fi
    else
      RESUMED="$RESUMED $id"; echo "The previous tab of $t (${!v}) no longer exists; opening a new one."
    fi
  fi
  h=""
  for try in 1 2 3; do
    h=$(orca terminal create --worktree "$WT" --title "$t" --command "ORCA_ROLES_CONFIG='$CFG' '$KIT/bin/agent.sh' $id${sid:+ --resume $sid}" --json 2>&1 | handle_of)
    [ -n "$h" ] && break
    echo "Retrying $t ($try/3)..."; sleep 2
  done
  [ -n "$h" ] || { echo "ERROR: could not open $t. Check $LOG" >&2; exit 1; }
  printf -v "$v" '%s' "$h"; NEW="$NEW $id"
done

: > "$STATE"; : > "$PTY"
for id in $ROLES; do v="$(var_of "$id")"; echo "$v=${!v}" >> "$STATE"; echo "$v=$(pty_of_handle "${!v}")" >> "$PTY"; done
cat "$STATE"

if [ -z "$NEW" ]; then echo "All roles are already open."; exit 0; fi
[ -n "$REMEMBERED" ] && echo "Resuming workspace:$REMEMBERED keep their conversation from before the restart."
[ -n "$RESUMED" ] && echo "Resuming workspace:$RESUMED start without memory; the Planner will recover the previous state and give you a summary."
nohup "$KICKOFF" "$WT" "$STATE" "$CFG" "$NEW" "$RESUMED" "$REMEMBERED" > "$GITDIR/orca-roles-kickoff.log" 2>&1 &
echo "Role kickoff in progress (log: $GITDIR/orca-roles-kickoff.log)"
