#!/usr/bin/env bash
# Opens the tabs of the worktree's enabled roles and starts their kickoff in the background.
# Usage: launch.sh [id:<worktree>] [exceptions]
#   --only a,b       only those roles (the planner always runs)
#   --enable a,b     enables roles disabled in the configuration
#   --disable a,b    disables roles
#   --set path=value any configuration key (e.g. roles.dev.model=claude-opus-5-5, settings.jiraHandoff=false)
#   --mode <mode>    the team's mode (programmer, pr-reviewer, academic-writer); beats .orca-roles.json and settings.mode;
#                    saved, and kept when later options omit it
#   (academic-writer: the phase, settings.phase, is changed with phase.sh, not by hand)
#   --reset          forgets this worktree's saved exceptions first, so only the options of this run apply
#   --status         shows the team (mode, each role's tab state and model) and exits; changes nothing in the worktree or Orca and opens nothing
# The exceptions go on the project's setup script line and are applied on top of config.json and .orca-roles.json.
# They are saved per worktree, so 'roles' without options applies them again when resuming. Options of a later run are added to the
# saved ones (the same option replaces its saved value: --only, --mode, a --set path; a role in --enable/--disable leaves the other list);
# --reset forgets the saved ones first. A different --mode also drops the saved --only/--enable/--disable (role selections belong to a mode).
# The mode of a worktree cannot change while its team is open: close the team first (close-role.sh, or its tabs).
# Only one launch runs per worktree at a time (orca-roles.lock in its git dir). If Orca cannot tell which tabs are open
# ("Orca is not ready"), it stops before closing or opening anything.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,19p "$0"; exit 0;; esac
command -v jq >/dev/null || { echo "ERROR: 'jq' is missing (macOS: brew install jq; Ubuntu: sudo apt install jq); orca-roles cannot read its configuration without it." >&2; exit 1; }
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
command -v orca >/dev/null || { echo "ERROR: Orca CLI not found (neither 'orca' nor \$ORCA_CLI_COMMAND). Run this from an Orca terminal." >&2; exit 1; }
WT=""; RESET=0; STATUS=0; FLAGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) RESET=1;;
    --status) STATUS=1;;
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
KICKED="$GITDIR/orca-roles.kicked"       # the handle each role had when kickoff.sh sent it its message
PTY="$GITDIR/orca-roles.pty"             # each role's ptyId: stable across restarts, unlike the handle (see restored_handle)
KICKOFF="${ORCA_ROLES_KICKOFF:-$KIT/bin/kickoff.sh}"
CFG="$GITDIR/orca-roles.config.json"     # copy of the effective config for this worktree
LOG="$GITDIR/orca-roles-launch.log"
# Whether a role's tab is still working: 0 alive, 1 no tab (no handle, or Orca says the handle is stale), 2 the tab exists but its agent
# is gone (e.g. after Ctrl+C), 3 its tab was closed with the X but Orca kept the session running without a tab ("orphaned"),
# 4 unknown: 'orca terminal show' failed for another reason (ROLE_ALIVE_CODE holds Orca's error code, or no-response).
# Orca reports the agent of a tab in agentIdentity for the agents it knows (claude, codex); for custom agents only the tab counts.
# An agent that is still starting has no identity for a moment, so it is checked a few times before giving up.
agent_in()   { orca terminal show --terminal "$1" --json 2>/dev/null | jq -r '[.. | objects | select(has("agentIdentity")) | .agentIdentity // empty] | first // empty' 2>/dev/null; }
role_alive() {  # role_alive <role> <handle>
  [ -n "${2:-}" ] || return 1
  local js rc code; js="$(orca terminal show --terminal "$2" --json 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    code="$(printf '%s' "$js" | jq -r '.error.code // empty' 2>/dev/null)"
    [ "$code" = terminal_handle_stale ] && return 1
    ROLE_ALIVE_CODE="${code:-no-response}"; return 4
  fi
  printf '%s' "$js" | jq -e '[.. | objects | select(has("orphaned")) | .orphaned] | first == true' >/dev/null 2>&1 && return 3
  case "$(rstr "$CFG" "$1" agent)" in claude|codex|"") ;; *) return 0;; esac
  local i; for i in $(seq 1 "${ORCA_ROLES_AGENT_CHECKS:-5}"); do
    [ -n "$(agent_in "$2")" ] && return 0
    [ "$i" -lt "${ORCA_ROLES_AGENT_CHECKS:-5}" ] && sleep 2
  done
  return 2
}
if [ "$STATUS" = 1 ]; then   # read-only: nothing is written, not even the launch log
  if [ ! -s "$STATE" ]; then echo "No team launched in this worktree."; exit 0; fi
  SCFG="$CFG"
  if [ ! -f "$CFG" ]; then   # no saved copy: the effective configuration, built aside and removed on exit
    SCFG="$(mktemp "${TMPDIR:-/tmp}/orca-roles-status.XXXXXX")"; trap 'rm -f "$SCFG" "$SCFG.x"' EXIT
    merged_config . > "$SCFG" 2>/dev/null || echo '{}' > "$SCFG"
    if [ -f "$OVR" ] && apply_overrides "$SCFG" "$OVR" > "$SCFG.x" 2>/dev/null; then mv "$SCFG.x" "$SCFG"; fi
  fi
  CFG="$SCFG"
  SMODE="$(jq -r '.settings.mode // "programmer"' "$SCFG" 2>/dev/null || echo programmer)"
  echo "Mode: $SMODE"
  [ "$SMODE" = academic-writer ] && echo "Phase: $(phase_of "$SCFG")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    var="${line%%=*}"; handle="${line#*=}"; role="$(printf '%s' "$var" | tr 'A-Z_' 'a-z-')"
    title="$(title_of "$SCFG" "$role")"; cm="$(rstr "$SCFG" "$role" model)"
    role_alive "$role" "$handle"; rc=$?
    case $rc in 0) st="alive";; 1) st="no tab";; 2) st="agent gone";; 4) st="unknown ($ROLE_ALIVE_CODE)";; *) st="orphaned";; esac
    used="$(grep "^$var=" "$GITDIR/orca-roles.models" 2>/dev/null | head -1 | cut -d= -f2-)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$title" "$handle" "$st" "${cm:--}" "${used:--}"
  done < "$STATE"
  exit 0
fi
# One launch per worktree at a time: the lock is a directory (mkdir is atomic) holding the pid of its owner
LOCK="$GITDIR/orca-roles.lock"
lock_release() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"; return 0; }
lock_take() {  # lock_take <pid read from the lock, "" if none>: a stale (or pid-less, after the wait) lock is moved aside first, so only one launch takes it over
  local got
  mv "$LOCK" "$LOCK.old.$$" 2>/dev/null || return 1
  got="$(cat "$LOCK.old.$$/pid" 2>/dev/null)"
  if [ "$got" != "$1" ]; then   # another launch took the lock over meanwhile: what was moved is its fresh lock, put it back
    if [ ! -e "$LOCK" ]; then mv "$LOCK.old.$$" "$LOCK" 2>/dev/null || rm -rf "$LOCK.old.$$"; else rm -rf "$LOCK.old.$$"; fi
    return 1
  fi
  rm -rf "$LOCK.old.$$"; mkdir "$LOCK" 2>/dev/null || return 1
  echo "$$" > "$LOCK/pid"
}
LOCK_WAIT="${ORCA_ROLES_LOCK_WAIT:-60}"; waited=0; announced=0
while :; do
  if mkdir "$LOCK" 2>/dev/null; then echo "$$" > "$LOCK/pid"; break; fi
  lp="$(cat "$LOCK/pid" 2>/dev/null)"
  if [ -n "$lp" ] && ! kill -0 "$lp" 2>/dev/null; then
    if lock_take "$lp"; then echo "Took over a stale lock (pid $lp is gone)."; break; fi
    continue
  fi
  if [ "$waited" -ge "$LOCK_WAIT" ]; then
    if [ -z "$lp" ]; then lock_take "" && break; continue; fi
    echo "ERROR: another roles is still running in this worktree (pid $lp). Nothing was changed. Run roles again when it finishes."; exit 1
  fi
  if [ -n "$lp" ] && [ "$announced" = 0 ]; then echo "Another roles is running in this worktree (pid $lp); waiting..."; announced=1; fi
  sleep 1; waited=$((waited + 1))
done
trap lock_release EXIT
exec > >(tee -a "$LOG") 2>&1
echo "== $(date '+%F %T') launch.sh in $WT"

# The new configuration and exceptions are prepared aside and only replace the saved ones once every check has passed
NEWCFG="$CFG.new"; NEWOVR="$OVR.tmp"; OVRSRC=""
fail() { rm -f "$NEWCFG" "$NEWCFG.tmp" "$NEWCFG.prev" "$NEWOVR" "$NEWOVR.x"; echo "$1"; exit 1; }
merged_config . > "$NEWCFG" || fail "ERROR: invalid configuration (check ~/.orca-roles/config.json and .orca-roles.json)"
PREV_MODE=""; [ -f "$CFG" ] && PREV_MODE="$(jq -r '.settings.mode // "programmer"' "$CFG" 2>/dev/null)"   # the mode of the last launch
if [ ${#FLAGS[@]} -gt 0 ]; then
  overrides_from_args "${FLAGS[@]}" > "$NEWOVR" || { rm -f "$NEWCFG" "$NEWOVR"; exit 1; }
  ERR="$(check_overrides "$NEWCFG" "$NEWOVR")"
  [ -z "$ERR" ] || fail "$ERR"
  # the options add to the saved ones (the same option replaces its saved value; --reset forgets them first)
  if [ "$RESET" != 1 ] && [ -f "$OVR" ]; then
    # role selections belong to a mode: compare the new mode with the one the saved options gave this worktree
    PREV_EFF_MODE="$(apply_overrides "$NEWCFG" "$OVR" > "$NEWCFG.prev" 2>/dev/null && mode_of "$NEWCFG.prev" 2>/dev/null)" || PREV_EFF_MODE=""
    rm -f "$NEWCFG.prev"; [ -n "$PREV_EFF_MODE" ] || PREV_EFF_MODE="programmer"
    if jq -e --slurpfile n "$NEWOVR" --arg p "$PREV_EFF_MODE" '($n[0].mode // null) as $m | $m != null and $m != $p and ((.only // []) + (.enable // []) + (.disable // []) | length) > 0' "$OVR" >/dev/null 2>&1; then
      echo "Mode changed to $(jq -r .mode "$NEWOVR"): this worktree's saved role selections (--only/--enable/--disable) were dropped."
    fi
    merge_overrides "$OVR" "$NEWOVR" "$PREV_EFF_MODE" > "$NEWOVR.x" && mv "$NEWOVR.x" "$NEWOVR" || fail "ERROR: could not combine the options with the saved exceptions ($OVR)"
    ERR="$(check_overrides "$NEWCFG" "$NEWOVR")"
    [ -z "$ERR" ] || fail "$ERR"
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
if [ "$NEWMODE" = academic-writer ] && ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "ERROR: mode academic-writer needs the project to be a git repository (git init, then run roles again). Nothing was changed."
fi

FRESH=0; [ -s "$STATE" ] || FRESH=1     # first launch in this worktree (not a resume)
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
    role_alive "$(printf '%s' "${line%%=*}" | tr 'A-Z_' 'a-z-')" "${line#*=}"; rc=$?
    [ "$rc" -ne 4 ] || fail "ERROR: Orca is not ready ($ROLE_ALIVE_CODE): cannot tell whether this worktree's team is still open. Nothing was changed. Run roles again once Orca is ready."
    [ "$rc" -eq 1 ] || OPEN=1
    p="$(saved_pty "${line%%=*}")"; [ -n "$p" ] && [ -n "$(restored_handle "$p")" ] && OPEN=1
    [ "$OPEN" = 1 ] || continue
    fail "ERROR: this worktree's team is open in mode '$PREV_MODE' and mode '$NEWMODE' was requested. Close the team first (close-role.sh on each worker, or close its tabs), then run roles again. Nothing was changed."
  done
fi
# The phase cannot change under an open team either: a role of the old phase that the new one does not have must be closed first (phase.sh does it).
if [ "$PREV_MODE" = academic-writer ] && [ "$NEWMODE" = academic-writer ] && [ -s "$STATE" ] && [ "$(phase_of "$CFG")" != "$(phase_of "$NEWCFG")" ]; then
  OLDPHASE="$(phase_of "$CFG")"; NEWPHASE="$(phase_of "$NEWCFG")"
  [ "$LISTOK" = 1 ] || fail "ERROR: cannot tell whether this worktree's team (phase '$OLDPHASE') is still open: 'orca terminal list' failed. Phase '$NEWPHASE' was requested; nothing was changed. Try again once Orca is ready."
  NEWENABLED="$(enabled_roles "$NEWCFG")"
  for line in $(cat "$STATE"); do
    OPEN=0
    [ -n "${line#*=}" ] || continue
    prole="$(printf '%s' "${line%%=*}" | tr 'A-Z_' 'a-z-')"
    [ "$prole" != planner ] || continue
    printf '%s\n' "$NEWENABLED" | grep -qxF "$prole" && continue
    role_alive "$prole" "${line#*=}"; rc=$?
    [ "$rc" -ne 4 ] || fail "ERROR: Orca is not ready ($ROLE_ALIVE_CODE): cannot tell whether this worktree's team is still open. Nothing was changed. Run roles again once Orca is ready."
    [ "$rc" -eq 1 ] || OPEN=1
    p="$(saved_pty "${line%%=*}")"; [ -n "$p" ] && [ -n "$(restored_handle "$p")" ] && OPEN=1
    [ "$OPEN" = 1 ] || continue
    fail "ERROR: this worktree's team is in phase '$OLDPHASE' and phase '$NEWPHASE' was requested while $(title_of "$CFG" "$prole") is still open. Change the phase with ~/.orca-roles/bin/phase.sh $NEWPHASE. Nothing was changed."
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
# The same folder under two worktree ids (Orca listing it twice) gets a full team under each
case "$WT" in
  id:*)
    OLDWT="$(cat "$GITDIR/orca-roles.wtid" 2>/dev/null)"
    case "$OLDWT" in id:*) [ "$OLDWT" = "$WT" ] || echo "Warning: this folder was launched before as worktree $OLDWT and now as $WT; if Orca lists it twice, its tabs may be duplicated.";; esac
    printf '%s\n' "$WT" > "$GITDIR/orca-roles.wtid";;
esac
echo "Mode: $NEWMODE"
if [ "$NEWMODE" = academic-writer ]; then
  echo "Phase: $(phase_of "$CFG")"
  "$KIT/bin/academic-scaffold.sh" "$(git rev-parse --show-toplevel)" || echo "Warning: could not create the academic-writer folders."
fi

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
state_set() {  # state_set <file> <VAR> <value>: replaces that line (or adds it), keeps the others, atomically
  local tmp="$1.tmp.$$"; [ -f "$1" ] || : > "$1"
  awk -v k="$2" -v v="$3" 'index($0, k "=") == 1 { if (!d) print k "=" v; d = 1; next } { print } END { if (!d) print k "=" v }' "$1" > "$tmp" && mv "$tmp" "$1"
}
# A team saved by an older kit has no marker file: all its tabs were kicked. Otherwise the file starts empty, before any tab is saved.
if [ ! -f "$KICKED" ]; then if [ -s "$STATE" ]; then cp "$STATE" "$KICKED"; else : > "$KICKED"; fi; fi
kicked_of() { grep "^$1=" "$KICKED" 2>/dev/null | head -1 | cut -d= -f2-; }
# Classify every role before closing or opening anything: if Orca cannot tell, the team is left exactly as it is
for id in $ROLES; do
  v="$(var_of "$id")"; t="$(title_of "$CFG" "$id")"
  role_alive "$id" "${!v:-}"; st=$?; printf -v "ST_$v" '%s' "$st"
  [ "$st" -ne 4 ] || fail "ERROR: Orca is not ready ($ROLE_ALIVE_CODE) for $t: no tab was closed or opened. Run roles again once Orca is ready."
  if [ "$LISTOK" != 1 ] && [ "$st" = 1 ] && [ -n "${!v:-}" ]; then
    fail "ERROR: 'orca terminal list' failed: cannot tell whether $t's tab was restored after a restart; no tab was closed or opened. Run roles again once Orca is ready."
  fi
done
KICKOFFS="$GITDIR/orca-roles.kickoff.d"   # one file per running kickoff, named by its pid, listing the roles it will kick
for f in "$KICKOFFS"/*; do [ -f "$f" ] && ! kill -0 "$(basename "$f")" 2>/dev/null && rm -f "$f"; done
kickoff_of() {  # kickoff_of <role>: prints the pid of a live kickoff that will still kick that role
  local f p
  for f in "$KICKOFFS"/*; do
    [ -f "$f" ] || continue
    p="$(basename "$f")"
    kill -0 "$p" 2>/dev/null || continue
    case " $(cat "$f") " in *" $1 "*) echo "$p"; return 0;; esac
  done
  return 1
}
NEW=""; REUSED=""; RESUMED=""; REMEMBERED=""   # RESUMED: roles reopened without memory (the Planner recovers the state); REMEMBERED: reopened with their conversation
for id in $ROLES; do
  v="$(var_of "$id")"; t="$(title_of "$CFG" "$id")"; sid=""
  sv="ST_$v"; st="${!sv}"
  if [ "$st" = 0 ]; then   # alive: reused as is, but a tab that never got its role message (interrupted launch) is kicked now
    if [ "$(kicked_of "$v")" != "${!v}" ]; then
      if kp="$(kickoff_of "$id")"; then echo "The kickoff of the previous launch is still running (pid $kp): $t gets its role from it."; continue; fi
      NEW="$NEW $id"; REUSED="$REUSED $id"; echo "The tab of $t (${!v}) never got its role message; sending it now."
    fi
    continue
  fi
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
  state_set "$STATE" "$v" "$h"; state_set "$PTY" "$v" "$(pty_of_handle "$h")"   # an interrupted launch still remembers the tabs it opened
done

: > "$STATE"; : > "$PTY"
for id in $ROLES; do v="$(var_of "$id")"; echo "$v=${!v}" >> "$STATE"; echo "$v=$(pty_of_handle "${!v}")" >> "$PTY"; done
"$KIT/bin/orca-yaml.sh" --check || true
cat "$STATE"

if [ -z "$NEW" ]; then echo "All roles are already open."; exit 0; fi
[ -n "$REMEMBERED" ] && echo "Resuming workspace:$REMEMBERED keep their conversation from before the restart."
[ -n "$RESUMED" ] && echo "Resuming workspace:$RESUMED start without memory; the Planner will recover the previous state and give you a summary."
case " $NEW " in *" planner "*) ;; *) [ "${ORCA_TERMINAL_HANDLE:-}" = "${PLANNER:-}" ] || echo 'The Planner kept its tab: it is told the new handles by a message ("Role handles changed"); if it does not pick them up, ask it to read its messages.';; esac
nohup "$KICKOFF" "$WT" "$STATE" "$CFG" "$NEW" "$RESUMED" "$REMEMBERED" "$REUSED" > "$GITDIR/orca-roles-kickoff.log" 2>&1 &
mkdir -p "$KICKOFFS" && printf '%s\n' "${NEW# }" > "$KICKOFFS/$!"
echo "Role kickoff in progress (log: $GITDIR/orca-roles-kickoff.log)"
