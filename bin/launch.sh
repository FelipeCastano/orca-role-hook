#!/usr/bin/env bash
# Opens the tabs of the worktree's enabled roles and starts their kickoff in the background.
# Usage: launch.sh [id:<worktree>] [exceptions]
#   --only a,b       only those roles (the planner and the mode's front role always run)
#   --enable a,b     enables roles disabled in the configuration
#   --disable a,b    disables roles
#   --set path=value any configuration key (e.g. roles.dev.model=claude-opus-5-5, settings.jiraHandoff=false)
#   --mode <mode>    the team's mode (programmer, pr-reviewer, academic-research); beats .orca-roles.json and settings.mode;
#                    saved, and kept when later options omit it
#   (academic-research: the phase, settings.phase, is changed with phase.sh, not by hand)
#   --reset          forgets this worktree's saved exceptions first, so only the options of this run apply
#   --status         shows the kit version, then the team (mode, each role's tab state and model) and exits; changes nothing in the worktree or Orca and opens nothing
#   --reopen         reopens only the roles whose saved tab is lost (they have a saved handle that no longer works); roles with no saved handle (closed with close-role.sh, or never opened) and live roles are left as they are. Takes no other option.
# The exceptions go on the project's setup script line and are applied on top of config.json and .orca-roles.json.
# They are saved per worktree, so 'roles' without options applies them again when resuming. Options of a later run are added to the
# saved ones (the same option replaces its saved value: --only, --mode, a --set path; a role in --enable/--disable leaves the other list);
# --reset forgets the saved ones first. A different --mode also drops the saved --only/--enable/--disable (role selections belong to a mode).
# The mode of a worktree cannot change while its team is open: close the team first (close-role.sh, or its tabs).
# Only one launch runs per worktree at a time (orca-roles.lock in its git dir). If Orca cannot tell which tabs are open
# ("Orca is not ready"), it stops before closing or opening anything.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,20p "$0"; exit 0;; esac
command -v jq >/dev/null || { echo "ERROR: 'jq' is missing (macOS: brew install jq; Ubuntu: sudo apt install jq); orca-roles cannot read its configuration without it." >&2; exit 1; }
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
type -P orca >/dev/null || { echo "ERROR: Orca CLI not found (neither 'orca' nor \$ORCA_CLI_COMMAND). Run this from an Orca terminal." >&2; exit 1; }
WT=""; RESET=0; STATUS=0; REOPEN=0; FLAGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) RESET=1;;
    --status) STATUS=1;;
    --reopen) REOPEN=1;;
    --only|--enable|--disable|--set|--mode) FLAGS+=("$1" "${2:-}"); shift;;
    -*) FLAGS+=("$1");;
    *) WT="$1";;
  esac
  shift
done
if [ "$REOPEN" = 1 ]; then
  OTHERS=""; [ ${#FLAGS[@]} -gt 0 ] && OTHERS="${FLAGS[*]}"
  [ "$RESET" = 1 ] && OTHERS="${OTHERS:+$OTHERS }--reset"; [ "$STATUS" = 1 ] && OTHERS="${OTHERS:+$OTHERS }--status"
  [ -z "$OTHERS" ] || { echo "ERROR: --reopen takes no other option (got: $OTHERS). Nothing was changed."; exit 1; }
fi
git_here_init
# a terminal of one worktree can be used in the folder of another: the folder's worktree wins over the terminal's
if [ -z "$WT" ] && [[ "${ORCA_WORKTREE_ID:-}" == *::* ]] && TOP="$(git_here toplevel)"; then
  A="${ORCA_WORKTREE_ID#*::}"; A="$(local_path "${A%%::workspace:*}")"
  if [ "$(cd "$A" 2>/dev/null && pwd -P)" != "$(cd "$TOP" && pwd -P)" ]; then
    CUR_ID="$(orca worktree current --json 2>/dev/null | jq -r '.result.worktree.id // empty' 2>/dev/null)"
    if [ -n "$CUR_ID" ]; then
      WT="id:$CUR_ID"
      echo "This terminal belongs to worktree $A; using the worktree of the current folder ($TOP)."
    else
      echo "ERROR: this terminal belongs to worktree $A but the current folder ($TOP) is not an Orca worktree. Run roles from a terminal of that worktree. Nothing was changed."
      exit 1
    fi
  fi
fi
WT="${WT:-${ORCA_WORKTREE_ID:+id:$ORCA_WORKTREE_ID}}"; WT="${WT:-active}"
GITDIR="$(git_here git-dir || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
OVR="$GITDIR/orca-roles.overrides.json"  # this worktree's exceptions
STATE="$GITDIR/orca-roles.env"
KICKED="$GITDIR/orca-roles.kicked"       # the handle each role had when kickoff.sh sent it its message
PTY="$GITDIR/orca-roles.pty"             # each role's ptyId: stable across restarts, unlike the handle (see restored_handle)
# each role's tab and pane ids: Orca restores them, so a tab Orca keeps asleep after a restart can be woken (see wake_tab)
TABS="$GITDIR/orca-roles.tabs"
KICKOFF="${ORCA_ROLES_KICKOFF:-$KIT/bin/kickoff.sh}"
CFG="$GITDIR/orca-roles.config.json"     # copy of the effective config for this worktree
LOG="$GITDIR/orca-roles-launch.log"
MARKER="$GITDIR/orca-roles.mode-pending"  # exists while the worktree has no chosen mode yet (the local coordinator asks the user)
SWITCH_FILE="$GITDIR/orca-roles.switch-from"  # exists while a mode switch has closed the old workers but the front role has not had its new role message yet
# Whether a role's tab is still working: 0 alive, 1 no tab (no handle, or Orca says the handle is stale), 2 the tab exists but its agent
# is gone (e.g. after Ctrl+C), 3 its tab was closed with the X but Orca kept the session running without a tab ("orphaned"),
# 4 unknown: 'orca terminal show' failed for another reason (ROLE_ALIVE_CODE holds Orca's error code, or no-response).
# Orca reports the agent of a tab in agentIdentity for the agents it knows (claude, codex); for custom agents only the tab counts.
# An agent that is still starting has no identity for a moment, so it is checked a few times before giving up.
# A live claude or codex process for the handle counts as alive even when Orca flags the tab orphaned (it also does for tabs it has not
# bound yet) or shows no agent identity (idle Claude often does); an orphaned one sets ROLE_DETACHED=1 so the caller can say it kept it.
# The pid of the claude or codex process whose ORCA_TERMINAL_HANDLE is that handle (none: the tab has no agent behind it).
agent_pid_of_handle() {
  [ -n "${ORCA_ROLES_AGENT_PID:-}" ] && { "$ORCA_ROLES_AGENT_PID" "$1"; return 0; }   # test hook
  local pid env
  for pid in $(ps -axo pid=,comm= 2>/dev/null | awk '$2 ~ /(^|\/)(claude|codex)$/ {print $1}'); do
    if [ -r "/proc/$pid/environ" ]; then env="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)"; else env="$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n')"; fi
    printf '%s\n' "$env" | grep -qx "ORCA_TERMINAL_HANDLE=$1" || continue
    echo "$pid"
    return 0
  done
  return 0
}
agent_in()   { local js rc; js="$(orca terminal show --terminal "$1" --json 2>/dev/null)"; rc=$?; printf '%s' "$js" | jq -r '[.. | objects | select(has("agentIdentity")) | .agentIdentity // empty] | first // empty' 2>/dev/null; return "$rc"; }
role_alive() {  # role_alive <role> <handle>
  ROLE_DETACHED=0
  [ -n "${2:-}" ] || return 1
  local js rc code; js="$(orca terminal show --terminal "$2" --json 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    code="$(printf '%s' "$js" | jq -r '.error.code // empty' 2>/dev/null)"
    [ "$code" = terminal_handle_stale ] && return 1
    ROLE_ALIVE_CODE="${code:-no-response}"; return 4
  fi
  local ag; ag="$(rstr "$CFG" "$1" agent)"
  if printf '%s' "$js" | jq -e '[.. | objects | select(has("orphaned")) | .orphaned] | first == true' >/dev/null 2>&1; then
    case "$ag" in claude|codex|"") [ -z "$(agent_pid_of_handle "$2")" ] || { ROLE_DETACHED=1; return 0; };; esac
    return 3
  fi
  case "$ag" in claude|codex|"") ;; *) return 0;; esac   # opencode: the tab counts; Orca sets agentIdentity only after mini's first message
  local i ai; for i in $(seq 1 "${ORCA_ROLES_AGENT_CHECKS:-5}"); do
    ai="$(agent_in "$2")" || { ROLE_ALIVE_CODE=no-response; return 4; }
    if [ -n "$ai" ]; then
      # Orca can list a tab after a restart with its old identity but no agent running
      [ -n "$(agent_pid_of_handle "$2")" ] || return 2
      return 0
    fi
    [ "$i" -lt "${ORCA_ROLES_AGENT_CHECKS:-5}" ] && sleep 2
  done
  [ -z "$(agent_pid_of_handle "$2")" ] || return 0
  return 2
}
if [ "$STATUS" = 1 ]; then   # read-only: nothing is written, not even the launch log
  kv="$(head -1 "$KIT/VERSION" 2>/dev/null)"; ki="$(head -1 "$KIT/.installed" 2>/dev/null)"   # what the installer recorded
  echo "Kit: ${kv:-unknown} (${ki:-unknown})"
  if [ ! -s "$STATE" ]; then echo "No team launched in this worktree."; exit 0; fi
  SCFG="$CFG"; SAVEDSRC=1
  if [ ! -f "$CFG" ]; then   # no saved copy: the effective configuration, built aside and removed on exit
    SAVEDSRC=0; SCFG="$(mktemp "${TMPDIR:-/tmp}/orca-roles-status.XXXXXX")"; trap 'rm -f "$SCFG" "$SCFG.x"' EXIT
    merged_config . > "$SCFG" 2>/dev/null || echo '{}' > "$SCFG"
    if [ -f "$OVR" ] && apply_overrides "$SCFG" "$OVR" > "$SCFG.x" 2>/dev/null; then mv "$SCFG.x" "$SCFG"; fi
  fi
  CFG="$SCFG"
  SMODE="$(jq -r '.settings.mode // "programmer"' "$SCFG" 2>/dev/null || echo programmer)"
  [ "$SAVEDSRC" = 1 ] && [ "$SMODE" = academic-writer ] && SMODE=academic-research   # configs saved by kits before v1.4
  if [ -e "$MARKER" ]; then echo "Mode: not chosen yet (suggested: $SMODE)"
  else
    echo "Mode: $SMODE"
    [ "$SMODE" = academic-research ] && echo "Phase: $(phase_of "$SCFG")"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    var="${line%%=*}"; handle="${line#*=}"; role="$(printf '%s' "$var" | tr 'A-Z_' 'a-z-')"
    title="$(title_of "$SCFG" "$role")"; cm="$(rstr "$SCFG" "$role" model)"
    role_alive "$role" "$handle"; rc=$?
    case $rc in 0) st="alive";; 1) st="no tab";; 2) st="agent gone";; 4) st="unknown ($ROLE_ALIVE_CODE)";; *) st="orphaned";; esac
    used="$(grep "^$var=" "$GITDIR/orca-roles.models" 2>/dev/null | head -1 | cut -d= -f2-)"
    # what the role last ran (agent@CLI version) and its prompt's sha1 prefix, from the last provenance line written by agent.sh
    prov="$(jq -r --arg r "$role" 'select(.role == $r) | "\(.agent // "-")@\(.cliVersion // "-")\t\((.promptSha // "-")[0:7])"' "$GITDIR/orca-roles.provenance.jsonl" 2>/dev/null | tail -1)"; [ -n "$prov" ] || prov="-$(printf '\t')-"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$title" "$handle" "$st" "${cm:--}" "${used:--}" "$prov"
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
trap 'lock_release; rm -f "$OVR.canon"' EXIT
exec > >(tee -a "$LOG") 2>&1
echo "== $(date '+%F %T') launch.sh in $WT"

# The new configuration and exceptions are prepared aside and only replace the saved ones once every check has passed
NEWCFG="$CFG.new"; NEWOVR="$OVR.tmp"; OVRSRC=""
fail() { rm -f "$NEWCFG" "$NEWCFG.tmp" "$NEWCFG.prev" "$NEWOVR" "$NEWOVR.x"; sw="${SWITCH_FROM:-}"; [ -n "$sw" ] || sw="$(cat "$SWITCH_FILE" 2>/dev/null)"
  m="$1"; [ -z "$sw" ] || { case "$m" in *.) ;; *) m="$m.";; esac; m="$m The workers of mode $sw were already closed: run roles again to finish the switch."; }
  echo "$m"; exit 1; }
merged_config . > "$NEWCFG" || fail "ERROR: invalid configuration (check ~/.orca-roles/config.json and .orca-roles.json)"
PREV_MODE=""; [ -f "$CFG" ] && PREV_MODE="$(jq -r '.settings.mode // "programmer"' "$CFG" 2>/dev/null)"   # the mode of the last launch
[ "$PREV_MODE" != academic-writer ] || PREV_MODE=academic-research   # configs saved by kits before v1.4
OVRUSE=""; if [ -f "$OVR" ] && [ "$RESET" != 1 ]; then OVRUSE="$OVR"; fi
FRESH=0; [ -s "$STATE" ] || FRESH=1     # first launch in this worktree (not a resume)
PENDING=0; [ -e "$MARKER" ] && PENDING=1
# A mode named by this run's options or by the saved exceptions was chosen by the user: nothing to ask
EXPLICIT=0; ex=0
while [ "$ex" -lt ${#FLAGS[@]} ]; do
  case "${FLAGS[$ex]}" in
    --mode|--mode=*|--set=settings.mode=*) EXPLICIT=1;;
    --set) case "${FLAGS[$((ex + 1))]:-}" in settings.mode=*) EXPLICIT=1;; esac;;
  esac
  ex=$((ex + 1))
done
if [ "$EXPLICIT" = 0 ] && [ -n "$OVRUSE" ] && jq -e '(.mode // null) != null or any(.set[]?; .path == ["settings","mode"])' "$OVRUSE" >/dev/null 2>&1; then EXPLICIT=1; fi
NEED=0; [ "$EXPLICIT" = 0 ] && { [ "$FRESH" = 1 ] || [ "$PENDING" = 1 ]; } && [ "$REOPEN" = 0 ] && NEED=1
if [ "$NEED" = 1 ] && CMK="$(coordinated_marker)" && [ -f "$CMK" ]; then   # a coordinator opened this worktree: it dispatches the task, nobody answers a question
  NEED=0
  echo "A coordinator opened this worktree: it starts in mode $(setting "$NEWCFG" mode programmer) (change it later from the local coordinator)."
fi
if [ "$NEED" = 1 ]; then   # a worktree with a Jira ticket is a programmer worktree: no question
  JCFG="$NEWCFG"
  if [ -n "$OVRUSE" ]; then apply_overrides "$NEWCFG" "$OVRUSE" > "$NEWCFG.jira" 2>/dev/null && JCFG="$NEWCFG.jira"; fi
  if [ ${#FLAGS[@]} -gt 0 ]; then
    overrides_from_args "${FLAGS[@]}" > "$NEWCFG.jflags" 2>/dev/null && apply_overrides "$JCFG" "$NEWCFG.jflags" > "$NEWCFG.jira2" 2>/dev/null && JCFG="$NEWCFG.jira2"
  fi
  JKEY=""; [ "$(setting "$JCFG" enableAskModeOnStart true)" = false ] || JKEY="$(worktree_jira "$WT" "$JCFG" | head -1)"
  rm -f "$NEWCFG.jflags" "$NEWCFG.jira" "$NEWCFG.jira2"
  if [ -n "$JKEY" ]; then
    FLAGS+=(--mode programmer); NEED=0
    echo "Jira ticket $JKEY: this worktree starts in mode programmer (change it later from the local coordinator)."
  fi
fi
if [ ${#FLAGS[@]} -gt 0 ]; then
  overrides_from_args "${FLAGS[@]}" > "$NEWOVR" || { rm -f "$NEWCFG" "$NEWOVR"; exit 1; }
  ERR="$(check_overrides "$NEWCFG" "$NEWOVR")"
  [ -z "$ERR" ] || fail "$ERR"
  # the options add to the saved ones (the same option replaces its saved value; --reset forgets them first)
  if [ -n "$OVRUSE" ]; then
    # role selections belong to a mode: compare the new mode with the one the saved options gave this worktree
    PREV_EFF_MODE="$(apply_overrides "$NEWCFG" "$OVRUSE" > "$NEWCFG.prev" 2>/dev/null && mode_of --saved "$NEWCFG.prev" 2>/dev/null)" || PREV_EFF_MODE=""
    rm -f "$NEWCFG.prev"; [ -n "$PREV_EFF_MODE" ] || PREV_EFF_MODE="programmer"
    if jq -e --slurpfile n "$NEWOVR" --arg p "$PREV_EFF_MODE" '($n[0].mode // null) as $m | $m != null and $m != $p and ((.only // []) + (.enable // []) + (.disable // []) | length) > 0' "$OVRUSE" >/dev/null 2>&1; then
      echo "Mode changed to $(jq -r .mode "$NEWOVR"): this worktree's saved role selections (--only/--enable/--disable) were dropped."
    fi
    merge_overrides "$OVRUSE" "$NEWOVR" "$PREV_EFF_MODE" > "$NEWOVR.x" && mv "$NEWOVR.x" "$NEWOVR" || fail "ERROR: could not combine the options with the saved exceptions ($OVR)"
    ERR="$(check_overrides "$NEWCFG" "$NEWOVR")"
    [ -z "$ERR" ] || fail "$ERR"
  fi
  OVRSRC="$NEWOVR"
elif [ -n "$OVRUSE" ]; then
  echo "Applying this worktree's saved exceptions ($OVR)."
  OVRSRC="$OVR"
fi
if [ -n "$OVRSRC" ]; then
  apply_overrides "$NEWCFG" "$OVRSRC" > "$NEWCFG.tmp" && mv "$NEWCFG.tmp" "$NEWCFG" || fail "ERROR: could not apply the exceptions in $OVRSRC"
fi
ERR="$(check_config "$NEWCFG" "$OVRSRC")"
[ -z "$ERR" ] || fail "$ERR"
NEWMODE="$(mode_of "$NEWCFG")"
ASK=0
if [ "$NEED" = 1 ] && [ "$(setting "$NEWCFG" enableAskModeOnStart true)" != false ]; then ASK=1; fi
# The front role of this run (it opens first, owns the Run and talks to the user): the local coordinator while the mode is being asked
# and in programmer mode, the Planner in the other modes. In programmer the Planner is one of the workers.
FRONT="$(front_role "$NEWMODE")"
if [ "$ASK" = 1 ] || { [ "$PENDING" = 1 ] && [ "$REOPEN" = 1 ]; }; then FRONT=local-coordinator; fi
FRONTV="$(var_of "$FRONT")"; FL="$(front_label "$FRONT")"; FLC="$(front_label "$FRONT" cap)"
if [ "$FRONT" = local-coordinator ] && ! jq -e '(.roles["local-coordinator"] | type) == "object" and .roles["local-coordinator"].enabled != false' "$NEWCFG" >/dev/null 2>&1; then
  BASECFG="$KIT/config.json"; [ -f "$BASECFG" ] || BASECFG="$KIT/config.default.json"
  fail "ERROR: programmer mode needs the local-coordinator role, missing or disabled in $BASECFG: run install.sh again, or remove the override that disables it"
fi
if [ "$ASK" = 0 ]; then
  if [ "$NEWMODE" = academic-research ] && ! git_here toplevel >/dev/null 2>&1; then
    fail "ERROR: mode academic-research needs the project to be a git repository (git init, then run roles again). Nothing was changed."
  fi
fi
handle_of() { jq -r '[.. | .handle? // empty] | first // empty'; }
pty_of_handle() { orca terminal show --terminal "$1" --json 2>/dev/null | jq -r '[.. | objects | select(has("ptyId")) | .ptyId] | first // empty' 2>/dev/null; }
saved_pty() { grep "^$1=" "$PTY" 2>/dev/null | head -1 | cut -d= -f2-; }
# After a restart (of the computer or of Orca), Orca restores the tabs that were open with NEW handles and, in each agent tab,
# relaunches the agent with 'claude --resume <session>' but without the kit's settings (model, auto mode, plugin, MCP...).
# The ptyId of a tab does not change, so the restored tab of a role is the worktree terminal whose ptyId is the saved one.
# The optional second argument is a handle to leave out: the old one of a tab Orca kept asleep, which it may still list next to the new one.
restored_handle() { printf '%s' "$LIST" | jq -r --arg p "$1" --arg s "${2:-}" '[.. | objects | select(has("handle") and .ptyId == $p and .handle != $s) | .handle] | first // empty' 2>/dev/null; }
# The old handle of a role's tab that this run woke (set in the wake block), for restored_handle's second argument.
woke_old() { local k="WOKE_OLD_$1"; printf '%s' "${!k:-}"; }
# role_alive for a saved handle, except that the old handle of a tab this run woke and found ready counts as no tab (1): the restored tab has another handle.
role_state() {  # role_state <var> <role> <handle>
  local wo; wo="$(woke_old "$1")"
  [ -z "$wo" ] || [ "${3:-}" != "$wo" ] || return 1
  role_alive "$2" "$3"
}
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
LROLES="$(launchable_roles "$NEWCFG" | tr '\n' ' ')"
if [ "$ASK" = 1 ] || { [ "$PENDING" = 1 ] && [ "$REOPEN" = 1 ]; }; then LROLES="$FRONT"; fi
# After a restart Orca keeps agent tabs asleep: not in the terminal list, no handle, until someone clicks them (then Orca resumes their session itself).
# Waking them first lets the code below see them as the restored tabs they are and reopen each with its conversation, instead of opening a second tab.
if [ "$LISTOK" = 1 ] && [ -s "$STATE" ]; then
  WAKE_ALL=0
  if [ "$PENDING" = 0 ] && [ "$ASK" = 0 ] && [ -n "$PREV_MODE" ] && [ "$PREV_MODE" != "$NEWMODE" ]; then WAKE_ALL=1; fi
  if [ "$PREV_MODE" = academic-research ] && [ "$NEWMODE" = academic-research ] && [ "$(phase_of "$CFG")" != "$(phase_of "$NEWCFG")" ]; then WAKE_ALL=1; fi
  # An old-layout team (PLANNER= and no LOCAL_COORDINATOR=) is refused while any of its tabs exists, so every saved tab must be seen: wake them all.
  if [ "$FRONT" = local-coordinator ] && grep -q '^PLANNER=' "$STATE" && ! grep -q '^LOCAL_COORDINATOR=' "$STATE"; then WAKE_ALL=1; fi
  WAKE_EXTRA=""   # a non-programmer choice from the pending state also needs the local coordinator's tab, to refuse it while it is open
  if [ "$PENDING" = 1 ] && [ "$ASK" = 0 ] && [ "$REOPEN" = 0 ] && [ "$NEWMODE" != programmer ]; then WAKE_EXTRA=local-coordinator; fi
  WAKE_MSG="Cannot wake tabs Orca kept asleep on this system; their roles are treated as closed."
  W_N=0; W_STOP=0
  for line in $(cat "$STATE"); do
    [ "$W_STOP" = 0 ] || break
    wv="${line%%=*}"; [ -n "${line#*=}" ] || continue
    wid="$(printf '%s' "$wv" | tr 'A-Z_' 'a-z-')"
    if [ "$WAKE_ALL" = 0 ]; then case " $LROLES $WAKE_EXTRA " in *" $wid "*) ;; *) continue;; esac; fi
    wp="$(saved_pty "$wv")"; [ -n "$wp" ] || continue
    wold="$(restored_handle "$wp")"
    wt="$(grep "^$wv=" "$TABS" 2>/dev/null | head -1 | cut -d= -f2-)"
    if [ -n "$wold" ]; then
      case "$(rstr "$CFG" "$wid" agent)" in claude|codex|"") ;; *) continue;; esac
      [ -z "$(agent_pid_of_handle "$wold")" ] || continue
      wsh="$(tabs_of_handle "$wold")"
      [ -z "$wsh" ] || wt="$wsh"
    fi
    wtab="${wt%% *}"; wleaf="${wt#* }"
    [ -n "$wtab" ] && [ -n "$wleaf" ] && [ "$wtab" != "$wt" ] || continue
    wtitle="$(title_of "$CFG" "$wid")"
    case "$WT" in
      id:*) ;;
      *) echo "Cannot wake tabs Orca kept asleep: this launch has no worktree id (ORCA_WORKTREE_ID is not set); their roles are treated as closed."; break;;
    esac
    reason="$(wake_tab "${WT#id:}" "$wtab" "$wleaf")"; wrc=$?
    case "$wrc" in
      0) W_ROLE[$W_N]="$wid"; W_PTY[$W_N]="$wp"; W_TITLE[$W_N]="$wtitle"; W_HANDLE[$W_N]=""; W_OLD[$W_N]="$wold"; W_VAR[$W_N]="$wv"; W_READY[$W_N]=0; W_N=$((W_N + 1));;
      2) echo "$WAKE_MSG"; W_STOP=1;;
      *) echo "Could not wake the tab of $wtitle ($reason); it is treated as closed.";;
    esac
  done
  if [ "$W_N" -gt 0 ]; then
    W_T0=$SECONDS
    for ((wi = 0; wi < W_N; wi++)); do
      if [ -n "${W_OLD[$wi]}" ]; then W_END[$wi]=$((W_T0 + ${ORCA_ROLES_WAKE_LISTED_BUDGET:-10})); else W_END[$wi]=$((W_T0 + ${ORCA_ROLES_WAKE_BUDGET:-30})); fi
      W_DONE[$wi]=0
    done
    while :; do
      NL="$(orca terminal list --worktree "$WT" --json 2>/dev/null)" && LIST="$NL"
      W_ALL=1
      for ((wi = 0; wi < W_N; wi++)); do
        [ "${W_READY[$wi]}" = 0 ] && [ "${W_DONE[$wi]}" = 0 ] || continue
        wh="$(restored_handle "${W_PTY[$wi]}" "${W_OLD[$wi]}")"
        if [ -n "$wh" ]; then W_HANDLE[$wi]="$wh"; fi
        wok=0
        if [ -n "$wh" ]; then
          wok=1
          wag="$(rstr "$CFG" "${W_ROLE[$wi]}" agent)"
          case "$wag" in claude|"") [ -n "$(session_of_handle "$wh")" ] || wok=0;; esac
          if [ "$wok" = 1 ]; then
            case "$wag" in claude|codex|"") orca terminal wait --terminal "$wh" --for tui-idle --timeout-ms 2000 --json >/dev/null 2>&1 || wok=0;; esac
          fi
        fi
        if [ "$wok" = 1 ]; then
          W_READY[$wi]=1; echo "Orca kept the tab of ${W_TITLE[$wi]} asleep after a restart; woke it."
          [ -z "${W_OLD[$wi]}" ] || printf -v "WOKE_OLD_${W_VAR[$wi]}" '%s' "${W_OLD[$wi]}"
        elif [ "$SECONDS" -ge "${W_END[$wi]}" ]; then
          W_DONE[$wi]=1
        else
          W_ALL=0
        fi
      done
      [ "$W_ALL" = 0 ] || break
      sleep "${ORCA_ROLES_WAKE_TICK:-1}"   # the budgets above stay whole seconds; only the pause between passes is tunable
    done
    [ -z "${ORCA_TERMINAL_HANDLE:-}" ] || orca terminal switch --terminal "$ORCA_TERMINAL_HANDLE" --json >/dev/null 2>&1 || true
    for ((wi = 0; wi < W_N; wi++)); do
      [ "${W_READY[$wi]}" = 0 ] || continue
      if [ -z "${W_HANDLE[$wi]}" ] && [ -n "${W_OLD[$wi]}" ]; then
        echo "The tab of ${W_TITLE[$wi]} (${W_OLD[$wi]}) has no agent running and Orca did not resume it; it is handled as an agent that is gone."
      elif [ -z "${W_HANDLE[$wi]}" ]; then
        echo "Could not wake the tab of ${W_TITLE[$wi]} (it did not appear in Orca's terminal list); it is treated as closed."
      else
        fail "ERROR: Orca woke the tab of ${W_TITLE[$wi]} but its conversation has not started yet; run roles again in a moment. No tab was opened."
      fi
    done
  fi
fi
# Whether a saved role's tab still exists: its saved handle, or, after a restart of Orca or the computer (new handles), the tab that has the
# role's saved ptyId.  tab_exists <VAR>
tab_exists() {
  local var="$1" role h rc p rh=""
  h="$(grep "^$var=" "$STATE" 2>/dev/null | head -1 | cut -d= -f2-)"; [ -n "$h" ] || return 1
  role="$(printf '%s' "$var" | tr 'A-Z_' 'a-z-')"
  role_state "$var" "$role" "$h"; rc=$?
  [ "$rc" -ne 4 ] || fail "ERROR: Orca is not ready ($ROLE_ALIVE_CODE): cannot tell whether this worktree's team is still open. Nothing was changed. Run roles again once Orca is ready."
  [ "$rc" -eq 1 ] || return 0
  p="$(saved_pty "$var")"; [ -n "$p" ] && rh="$(restored_handle "$p" "$(woke_old "$var")")"
  [ -n "$rh" ]
}
# Whether any role of the saved team has a tab.  team_tabs_exist
team_tabs_exist() {
  local line
  for line in $(cat "$STATE" 2>/dev/null); do tab_exists "${line%%=*}" && return 0; done
  return 1
}
drop_role_lines() { local f; for f in "$STATE" "$PTY" "$KICKED" "$TABS"; do [ -f "$f" ] && { grep -v "^$1=" "$f" > "$f.tmp"; mv "$f.tmp" "$f"; }; done; return 0; }
# Programmer <-> another mode would move the front role between the local coordinator and the Planner: not in this version.
if [ "$PENDING" = 0 ] && [ "$ASK" = 0 ] && [ -n "$PREV_MODE" ] && [ "$PREV_MODE" != "$NEWMODE" ] && [ -s "$STATE" ] \
   && [ "$(front_role "$PREV_MODE")" != "$(front_role "$NEWMODE")" ]; then
  [ "$LISTOK" = 1 ] || fail "ERROR: cannot tell whether this worktree's team (mode '$PREV_MODE') is still open: 'orca terminal list' failed. Mode '$NEWMODE' was requested; nothing was changed. Try again once Orca is ready."
  if team_tabs_exist; then
    OTHER="$NEWMODE"; [ "$NEWMODE" != programmer ] || OTHER="$PREV_MODE"
    fail "ERROR: switching between programmer and $OTHER is not available in this version: start $OTHER in a new worktree with roles --mode $OTHER"
  fi
fi
# A team opened by a kit that had no local coordinator (PLANNER= and no LOCAL_COORDINATOR= in the state) cannot be reused by this one: while
# any of its tabs exists, the user closes them; with none, its state files go and the launch is a fresh one (it keeps the worktree's saved mode).
if [ "$FRONT" = local-coordinator ] && [ -s "$STATE" ] && grep -q '^PLANNER=' "$STATE" && ! grep -q '^LOCAL_COORDINATOR=' "$STATE"; then
  [ "$LISTOK" = 1 ] || fail "ERROR: cannot tell whether this worktree's earlier team is still open: 'orca terminal list' failed; nothing was changed. Try again once Orca is ready."
  if team_tabs_exist; then
    fail "ERROR: this worktree's team was opened by an earlier version of the kit: close its tabs and run roles again"
  fi
  rm -f "$STATE" "$KICKED" "$GITDIR/orca-roles.planner-handles" "$PTY" "$TABS" "$SWITCH_FILE"
  FRESH=1; PREV_MODE=""
  echo "This worktree's earlier team has no open tabs: its saved state was removed and a new team starts."
  if [ "$REOPEN" = 1 ]; then echo "Nothing to reopen: run roles to start the team."; exit 0; fi
fi
# A mode other than programmer chosen from the pending state: the local coordinator's tab must be closed first (its conversation is the
# programmer one). With no such tab, its lines leave the state and the chosen mode starts as a fresh team with the Planner in front.
if [ "$PENDING" = 1 ] && [ "$ASK" = 0 ] && [ "$REOPEN" = 0 ] && [ "$NEWMODE" != programmer ] && grep -q '^LOCAL_COORDINATOR=' "$STATE" 2>/dev/null; then
  [ "$LISTOK" = 1 ] || fail "ERROR: cannot tell whether the local coordinator's tab is still open: 'orca terminal list' failed; nothing was changed. Try again once Orca is ready."
  if tab_exists LOCAL_COORDINATOR; then
    fail "ERROR: $NEWMODE cannot be chosen while the local coordinator's tab is open: close it and run roles --mode $NEWMODE from a terminal of this worktree"
  fi
  drop_role_lines LOCAL_COORDINATOR
fi
SWITCH_FROM=""
# The mode cannot change under an open team: its tabs belong to the previous mode. Any tab of the saved team that still exists counts: its saved
# handle, or, after a restart of Orca or the computer (new handles), the tab that has the role's saved ptyId.
if [ "$PENDING" = 0 ] && [ "$ASK" = 0 ] && [ -n "$PREV_MODE" ] && [ "$PREV_MODE" != "$NEWMODE" ] && [ -s "$STATE" ]; then
  [ "$LISTOK" = 1 ] || fail "ERROR: cannot tell whether this worktree's team (mode '$PREV_MODE') is still open: 'orca terminal list' failed. Mode '$NEWMODE' was requested; nothing was changed. Try again once Orca is ready."
  SAVED_PLANNER="$(grep "^$FRONTV=" "$STATE" 2>/dev/null | head -1 | cut -d= -f2-)"
  IS_PLANNER=0; [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && [ "$ORCA_TERMINAL_HANDLE" = "$SAVED_PLANNER" ] && IS_PLANNER=1
  if [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && [ "$ORCA_TERMINAL_HANDLE" != "$SAVED_PLANNER" ]; then
    SP="$(saved_pty "$FRONTV")"; MP="$(pty_of_handle "$ORCA_TERMINAL_HANDLE")"
    if [ -n "$MP" ] && [ "$MP" = "$SP" ]; then
      fail "ERROR: your tab was restored by Orca after a restart: run roles (without options) first so the kit reopens you, then switch the mode. If it cannot reopen you, run roles from another terminal of this worktree. Nothing was changed."
    fi
  fi
  OPEN_LIST=""; OPEN_WORKERS=""; SW_RECORDS=""
  for line in $(cat "$STATE"); do
    OPEN=0; rh=""
    [ -n "${line#*=}" ] || continue
    srole="$(printf '%s' "${line%%=*}" | tr 'A-Z_' 'a-z-')"
    role_state "${line%%=*}" "$srole" "${line#*=}"; rc=$?
    [ "$rc" -ne 4 ] || fail "ERROR: Orca is not ready ($ROLE_ALIVE_CODE): cannot tell whether this worktree's team is still open. Nothing was changed. Run roles again once Orca is ready."
    [ "$rc" -eq 1 ] || OPEN=1
    p="$(saved_pty "${line%%=*}")"; [ -n "$p" ] && rh="$(restored_handle "$p" "$(woke_old "${line%%=*}")")"
    [ -z "$rh" ] || OPEN=1
    stitle="$(title_of "$CFG" "$srole")"
    if [ "$OPEN" = 1 ]; then
      OPEN_LIST="${OPEN_LIST:+$OPEN_LIST, }$stitle (${rh:-${line#*=}})"
      [ "$srole" = "$FRONT" ] || OPEN_WORKERS="${OPEN_WORKERS:+$OPEN_WORKERS, }$stitle"
    fi
    SW_RECORDS="$SW_RECORDS${SW_RECORDS:+
}${line%%=*}|$srole|$OPEN|$rc|${line#*=}|$rh|$stitle"
  done
  if [ -n "$OPEN_LIST" ] && [ "$IS_PLANNER" = 0 ]; then
    fail "ERROR: this worktree's team is open in mode '$PREV_MODE' and mode '$NEWMODE' was requested. Open tabs: $OPEN_LIST. Ask $FL to switch modes, or close those tabs, then run roles again. Nothing was changed."
  fi
  if [ -n "$OPEN_LIST" ]; then
    for f in "$GITDIR/orca-roles.kickoff.d"/*; do
      [ -f "$f" ] && kill -0 "$(basename "$f")" 2>/dev/null && fail "ERROR: the previous launch's kickoff is still running (pid $(basename "$f")): try again in a moment. Nothing was changed."
    done
    echo "Switching mode from $PREV_MODE to $NEWMODE: closing ${OPEN_WORKERS:-no workers}; $FL keeps its tab and gets its role message for $NEWMODE after its conversation is cleared."
    while IFS='|' read -r svar srole sopen src shandle srh stitle; do
      [ -n "$svar" ] && [ "$srole" != "$FRONT" ] || continue
      if [ "$sopen" = 1 ]; then
        chs=""; case "$src" in 0|2|3) chs="$shandle";; esac
        [ -z "$srh" ] || [ "$srh" = "$chs" ] || chs="$chs $srh"
        for ch in $chs; do
          orca terminal close --terminal "$ch" --tab --json >/dev/null 2>&1; crc=$?
          [ "$crc" = 0 ] || [ "$crc" = 124 ] || { orca terminal close --terminal "$ch" --json >/dev/null 2>&1; crc=$?; }
          [ "$crc" = 0 ] || { [ "$crc" = 124 ] && close_unconfirmed "$ch" "$stitle" >/dev/null; } \
            || fail "ERROR: could not close $stitle's tab ($ch); close it by hand and switch again."
        done
      fi
      drop_role_lines "$svar"
    done <<EOF2
$SW_RECORDS
EOF2
    SWITCH_FROM="$PREV_MODE"
    printf '%s\n' "$PREV_MODE" > "$SWITCH_FILE.tmp.$$"; mv "$SWITCH_FILE.tmp.$$" "$SWITCH_FILE"
  fi
fi
if [ -z "$SWITCH_FROM" ] && [ -s "$SWITCH_FILE" ]; then
  SWITCH_FROM="$(cat "$SWITCH_FILE")"
  echo "Finishing the mode switch from $SWITCH_FROM to $NEWMODE that a previous launch left unfinished."
fi
# The phase cannot change under an open team either: a role of the old phase that the new one does not have must be closed first (phase.sh does it).
if [ "$PREV_MODE" = academic-research ] && [ "$NEWMODE" = academic-research ] && [ -s "$STATE" ] && [ "$(phase_of "$CFG")" != "$(phase_of "$NEWCFG")" ]; then
  OLDPHASE="$(phase_of "$CFG")"; NEWPHASE="$(phase_of "$NEWCFG")"
  [ "$LISTOK" = 1 ] || fail "ERROR: cannot tell whether this worktree's team (phase '$OLDPHASE') is still open: 'orca terminal list' failed. Phase '$NEWPHASE' was requested; nothing was changed. Try again once Orca is ready."
  NEWENABLED="$(enabled_roles "$NEWCFG")"
  for line in $(cat "$STATE"); do
    OPEN=0
    [ -n "${line#*=}" ] || continue
    prole="$(printf '%s' "${line%%=*}" | tr 'A-Z_' 'a-z-')"
    [ "$prole" != "$FRONT" ] || continue
    printf '%s\n' "$NEWENABLED" | grep -qxF "$prole" && continue
    role_state "${line%%=*}" "$prole" "${line#*=}"; rc=$?
    [ "$rc" -ne 4 ] || fail "ERROR: Orca is not ready ($ROLE_ALIVE_CODE): cannot tell whether this worktree's team is still open. Nothing was changed. Run roles again once Orca is ready."
    [ "$rc" -eq 1 ] || OPEN=1
    p="$(saved_pty "${line%%=*}")"; [ -n "$p" ] && [ -n "$(restored_handle "$p" "$(woke_old "${line%%=*}")")" ] && OPEN=1
    [ "$OPEN" = 1 ] || continue
    fail "ERROR: this worktree's team is in phase '$OLDPHASE' and phase '$NEWPHASE' was requested while $(title_of "$CFG" "$prole") is still open. Change the phase with ~/.orca-roles/bin/phase.sh $NEWPHASE. Nothing was changed."
  done
fi
# A choice made from a front role tab Orca restored after a restart: its kit settings are missing, so it must be reopened first
if [ "$PENDING" = 1 ] && [ "$ASK" = 0 ] && [ "$REOPEN" = 0 ] && [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
  SAVED_PLANNER="$(grep "^$FRONTV=" "$STATE" 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ "$ORCA_TERMINAL_HANDLE" != "$SAVED_PLANNER" ]; then
    SP="$(saved_pty "$FRONTV")"
    if [ -n "$SP" ] && [ "$SP" = "$(pty_of_handle "$ORCA_TERMINAL_HANDLE")" ]; then
      fail "ERROR: your tab was restored by Orca after a restart: run roles (without options) first so the kit reopens you, then choose the mode. If it cannot reopen you, run roles from another terminal of this worktree. Nothing was changed."
    fi
  fi
fi
# Everything checked: the new configuration and exceptions become the saved ones
jq --arg m "$NEWMODE" '.settings.mode = $m' "$NEWCFG" > "$NEWCFG.tmp" && mv "$NEWCFG.tmp" "$NEWCFG"   # the effective mode, explicit for the other scripts
mv "$NEWCFG" "$CFG"
CHOSEN=0
if [ "$ASK" = 1 ]; then : > "$MARKER"
elif [ "$PENDING" = 1 ] && [ "$REOPEN" = 0 ]; then rm -f "$MARKER"; CHOSEN=1; echo "Mode chosen: $NEWMODE."; fi
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
if [ "$ASK" = 1 ] || { [ "$PENDING" = 1 ] && [ "$REOPEN" = 1 ]; }; then
  echo "Mode: not chosen yet (suggested: $NEWMODE)"
else
  echo "Mode: $NEWMODE"
  if [ "$NEWMODE" = academic-research ]; then
    echo "Phase: $(phase_of "$CFG")"
    "$KIT/bin/academic-scaffold.sh" "$(git_here toplevel)" || echo "Warning: could not create the academic-research folders."
  fi
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
E2EDIR="$(jq -r '.roles["e2e-tester"].params.e2eDir // "qa-e2e"' "$CFG")"
if COMMON="$(git_here common-dir)"; then
  mkdir -p "$COMMON/info"; touch "$COMMON/info/exclude"
  for p in research/ "$EVID/" "/$E2EDIR/"; do grep -qxF "$p" "$COMMON/info/exclude" || echo "$p" >> "$COMMON/info/exclude"; done
fi
if [ -n "$(git -C "$(git_here toplevel)" ls-files -- "$E2EDIR" 2>/dev/null | head -1)" ]; then
  echo "Warning: files under $E2EDIR/ are tracked by git; the kit's E2E flows folder should not be (it is kept out of git)."
fi

# shellcheck source=/dev/null
[ -f "$STATE" ] && . "$STATE"
ROLES="$LROLES"
if [ "$ASK" = 1 ]; then
  echo "No mode chosen yet: only the local coordinator is opened; it asks which mode to use (settings.enableAskModeOnStart)."
fi
for id in $ROLES; do d="$(scratch_dir "$id")" && mkdir -p "$d"; done   # each role's scratch folder (outside the worktree)
if session_hook_enabled; then ensure_session_hook_or_warn; fi   # the SessionStart hook that re-binds a reopened tab's Runs
if [ "$(trust_of "$CFG")" = never ]; then
  echo "The folder is not marked as trusted (settings.trust is \"never\"): the agents will ask you to trust it; answer in each tab."
else
  for id in $ROLES; do case "$(rstr "$CFG" "$id" agent)" in claude|"") trust_folder; break;; esac; done
  trust_custom_roles "$CFG" "$ROLES"   # custom agents that define how to trust the folder (role field "trust")
fi
state_set() {  # state_set <file> <VAR> <value>: replaces that line (or adds it), keeps the others, atomically
  local tmp="$1.tmp.$$"; [ -f "$1" ] || : > "$1"
  k="$2" v="$3" awk 'index($0, ENVIRON["k"] "=") == 1 { if (!d) print ENVIRON["k"] "=" ENVIRON["v"]; d = 1; next } { print } END { if (!d) print ENVIRON["k"] "=" ENVIRON["v"] }' "$1" > "$tmp" && mv "$tmp" "$1"
}
# A team saved by an older kit has no marker file: all its tabs were kicked. Otherwise the file starts empty, before any tab is saved.
if [ ! -f "$KICKED" ]; then if [ -s "$STATE" ]; then cp "$STATE" "$KICKED"; else : > "$KICKED"; fi; fi
kicked_of() { grep "^$1=" "$KICKED" 2>/dev/null | head -1 | cut -d= -f2-; }
# Classify every role before closing or opening anything: if Orca cannot tell, the team is left exactly as it is
KEPT_DETACHED=""   # roles kept by the orphaned-with-live-agent rule (recorded as metrics events once the team's state is written)
for id in $ROLES; do
  v="$(var_of "$id")"; t="$(title_of "$CFG" "$id")"
  role_state "$v" "$id" "${!v:-}"; st=$?; printf -v "ST_$v" '%s' "$st"
  [ "$st" != 0 ] || [ "$ROLE_DETACHED" != 1 ] || { KEPT_DETACHED="$KEPT_DETACHED $id"; echo "Orca reports the tab of $t (${!v}) as detached but its agent is running; keeping it. If you closed that tab, run ~/.orca-roles/bin/close-role.sh $id and then roles."; }
  [ "$st" -ne 4 ] || fail "ERROR: Orca is not ready ($ROLE_ALIVE_CODE) for $t: no tab was closed or opened. Run roles again once Orca is ready."
  if [ "$LISTOK" != 1 ] && [ "$st" = 1 ] && [ -n "${!v:-}" ]; then
    fail "ERROR: 'orca terminal list' failed: cannot tell whether $t's tab was restored after a restart; no tab was closed or opened. Run roles again once Orca is ready."
  fi
  if [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && [ -n "${!v:-}" ]; then   # a tab this run would close must not be the one running it (the front role's restored tab is reopened by its relauncher)
    own=0
    if [ "$st" = 2 ]; then [ "${!v}" = "$ORCA_TERMINAL_HANDLE" ] && own=1
    elif [ "$st" = 1 ] && [ "$id" != "$FRONT" ]; then
      p="$(saved_pty "$v")"; [ -n "$p" ] && [ "$(restored_handle "$p" "$(woke_old "$v")")" = "$ORCA_TERMINAL_HANDLE" ] && own=1
    fi
    [ "$own" = 0 ] || fail "ERROR: roles was run from the tab of $t, which has to be reopened; run roles from $FL's tab or another terminal of this worktree. No tab was closed or opened."
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
oc_forget() { [ "$(rstr "$CFG" "$1" agent)" = opencode ] && oc_session_delete "$1" "$GITDIR"; return 0; }   # an OpenCode role replaced without memory: its saved session goes
NEW=""; REUSED=""; RESUMED=""; REMEMBERED=""   # RESUMED: roles reopened without memory (the front role recovers the state); REMEMBERED: reopened with their conversation
SELF_RELAUNCH=0; SELF_HANDLE=""; PLANNER_KEEP_PTY=""; PLANNER_BUSY=0; SELF_NO_SESSION=0   # the front role's restored tab runs this launch: it is reopened later by its relauncher; its saved ptyId is kept
for id in $ROLES; do
  v="$(var_of "$id")"; t="$(title_of "$CFG" "$id")"; sid=""
  sv="ST_$v"; st="${!sv}"
  if [ "$REOPEN" = 1 ] && [ -z "${!v:-}" ]; then echo "$t has no saved tab (closed on purpose or never opened); leaving it closed."; continue; fi
  if [ "$st" = 0 ] && [ "$id" = "$FRONT" ] && [ "$CHOSEN" = 1 ]; then
    NEW="$NEW $id"; REUSED="$REUSED $id"; echo "$FLC gets its role message for mode $NEWMODE."; continue
  fi
  if [ "$st" = 0 ] && [ "$id" = "$FRONT" ] && [ -n "$SWITCH_FROM" ]; then
    NEW="$NEW $id"; REUSED="$REUSED $id"; echo "$FLC gets its role message for mode $NEWMODE after a context clear."; continue
  fi
  if [ "$st" = 0 ]; then   # alive: reused as is, but a tab that never got its role message (interrupted launch) is kicked now
    if [ "$(kicked_of "$v")" != "${!v}" ]; then
      if kp="$(kickoff_of "$id")"; then echo "The kickoff of the previous launch is still running (pid $kp): $t gets its role from it."; continue; fi
      NEW="$NEW $id"; REUSED="$REUSED $id"; echo "The tab of $t (${!v}) never got its role message; sending it now."
    fi
    continue
  fi
  if [ "$st" = 3 ]; then
    RESUMED="$RESUMED $id"; echo "The tab of $t (${!v}) was closed but Orca kept its session running; ending it and opening a new one."
    oc_forget "$id"
    orca terminal close --terminal "${!v}" --json >/dev/null 2>&1; crc=$?
    [ "$crc" = 0 ] || [ "$crc" = 124 ] || { orca terminal close --terminal "${!v}" --tab --json >/dev/null 2>&1; crc=$?; }
    [ "$crc" != 124 ] || close_unconfirmed "${!v}" "$t" || true
  elif [ "$st" = 2 ]; then
    RESUMED="$RESUMED $id"; echo "The agent in the tab of $t (${!v}) is gone; closing that tab and opening a new one."
    oc_forget "$id"
    orca terminal close --terminal "${!v}" --tab --json >/dev/null 2>&1 || { [ $? != 124 ] || close_unconfirmed "${!v}" "$t" || true; }
  elif [ -n "${!v:-}" ]; then
    p="$(saved_pty "$v")"; rh=""; [ -n "$p" ] && rh="$(restored_handle "$p" "$(woke_old "$v")")"
    if [ -n "$rh" ]; then
      if [ "$id" = "$FRONT" ] && [ "$rh" = "${ORCA_TERMINAL_HANDLE:-}" ]; then
        PLANNER_KEEP_PTY="$p"
        planner_history_add "$GITDIR" "$ORCA_TERMINAL_HANDLE"   # this tab's handle joins the history: once a later tab of the front role is kicked, a Run bound to it is an old one
        sid=""; case "$(rstr "$CFG" "$id" agent)" in claude|"") sid="$(session_of_handle "$rh")";; esac
        if [ -n "$sid" ]; then
          SELF_RELAUNCH=1; SELF_HANDLE="$rh"
          echo "$FLC runs this launch from its restored tab ($rh): it will be reopened with the kit's settings and its conversation when this turn ends."
        else   # reopening it would lose a conversation that is intact: the front role keeps its tab
          SELF_NO_SESSION=1
          echo "Cannot start $FL's relauncher: its conversation could not be read from this tab (agent not claude, or a claude install that hides --resume); $FL keeps working here without the kit's settings. Run roles from another terminal of this worktree if you want it reopened with them (it may then start without memory)."
        fi
        continue
      fi
      case "$(rstr "$CFG" "$id" agent)" in
        claude|"") sid="$(session_of_handle "$rh")";;
        opencode) ocf="$(oc_session_file "$id" "$GITDIR")" && [ -f "$ocf" ] && sid="$(head -1 "$ocf")";;   # the id agent.sh saved: --session continues it
      esac
      if [ "$id" = "$FRONT" ] && [ "${ORCA_ROLES_RELAUNCH:-}" = 1 ] && [ -z "$sid" ]; then
        PLANNER_KEEP_PTY="$p"
        echo "$FLC's conversation could not be read from its restored tab ($rh): not reopened, to keep it."
        continue
      fi
      if [ "$id" = "$FRONT" ] && [ -n "$sid" ] && ! orca terminal wait --terminal "$rh" --for tui-idle --timeout-ms 2000 --json >/dev/null 2>&1; then
        PLANNER_KEEP_PTY="$p"; PLANNER_BUSY=1
        echo "$FLC's restored tab ($rh) is busy: not reopened now; run roles again when it is idle."
        continue
      fi
      orca terminal close --terminal "$rh" --tab --json >/dev/null 2>&1 || { [ $? != 124 ] || close_unconfirmed "$rh" "$t" || true; }
      if [ -n "$sid" ]; then
        REMEMBERED="$REMEMBERED $id"; echo "Orca restored the tab of $t after a restart ($rh) without the kit's settings; reopening it with its conversation ($sid)."
      else
        RESUMED="$RESUMED $id"; echo "Orca restored the tab of $t after a restart ($rh), but its session could not be read; closing it and opening a new one."
      fi
    else
      RESUMED="$RESUMED $id"; echo "The previous tab of $t (${!v}) no longer exists; opening a new one."
      oc_forget "$id"
    fi
  fi
  h=""
  for try in 1 2 3; do
    out="$(orca terminal create --worktree "$WT" --title "$(tab_title_of "$CFG" "$id")" --command "$(kit_env)ORCA_ROLES_CONFIG='$CFG' '$KIT/bin/agent.sh' $id${sid:+ --resume $sid}" --json 2>&1)"; crc=$?
    h="$(printf '%s' "$out" | handle_of)"
    if [ "$crc" = 124 ]; then
      # The list is read once, so a tab Orca opens after it is missed (N2).
      NL="$(orca terminal list --worktree "$WT" --json 2>/dev/null)" || NL=""
      for c in $(printf '%s' "$NL" | jq -r --arg t "$(tab_title_of "$CFG" "$id")" '[.. | objects | select(has("handle") and .title == $t) | .handle] | .[]' 2>/dev/null); do
        printf '%s' "$LIST" | grep -qF "\"$c\"" && continue
        h="$c"; echo "Orca was slow to answer while opening the tab of $t; using the tab it opened ($h)."; break
      done
    fi
    [ -n "$h" ] && break
    echo "Retrying $t ($try/3)..."; pace 2
  done
  if [ -z "$h" ]; then
    sw="${SWITCH_FROM:-}"; [ -n "$sw" ] || sw="$(cat "$SWITCH_FILE" 2>/dev/null)"
    m="ERROR: could not open $t. Check $LOG"; [ -z "$sw" ] || { case "$m" in *.) ;; *) m="$m.";; esac; m="$m The workers of mode $sw were already closed: run roles again to finish the switch."; }
    echo "$m" >&2; exit 1
  fi
  printf -v "$v" '%s' "$h"; NEW="$NEW $id"
  hp="$(pty_of_handle "$h")"
  if [ -z "$hp" ]; then
    pace 2; hp="$(pty_of_handle "$h")"
    [ -n "$hp" ] || echo "Could not read the ptyId of the tab of $t; after a restart it may open without memory."
  fi
  state_set "$STATE" "$v" "$h"; state_set "$PTY" "$v" "$hp"   # an interrupted launch still remembers the tabs it opened
  tl="$(tabs_of_handle "$h")"; [ -z "$tl" ] || state_set "$TABS" "$v" "$tl"
done

if metrics_enabled "$CFG"; then   # what the metrics pass cannot read itself: the worktree's project and task, and the kit's events
  MTOP="$(git_here toplevel)" && MPHYS="$(cd "$MTOP" && pwd -P)" || { MTOP="$PWD"; MPHYS="$(pwd -P)"; }
  metrics_worktree "$MTOP" "$(project_name .)" "$(metrics_task "$CFG" "$MTOP")"
  metrics_event "$MPHYS" launch ""
  [ "${ORCA_ROLES_RELAUNCH:-}" != 1 ] || metrics_event "$MPHYS" relaunch "$FRONT"
  for id in $REMEMBERED $RESUMED; do metrics_event "$MPHYS" reopened "$id"; done
  for id in $KEPT_DETACHED; do metrics_event "$MPHYS" detached-kept "$id"; done
fi
PREV_TABS="$(cat "$TABS" 2>/dev/null)"
: > "$STATE"; : > "$PTY"; : > "$TABS.tmp.$$"
for id in $ROLES; do   # a role with no saved tab (left closed) is not written back as VAR=
  v="$(var_of "$id")"; [ -n "${!v:-}" ] || continue
  echo "$v=${!v}" >> "$STATE"
  if [ "$id" = "$FRONT" ] && [ -n "$PLANNER_KEEP_PTY" ]; then
    echo "$v=$PLANNER_KEEP_PTY" >> "$PTY"
    tl="$(printf '%s\n' "$PREV_TABS" | grep "^$v=" | head -1 | cut -d= -f2-)"
  else
    echo "$v=$(pty_of_handle "${!v}")" >> "$PTY"
    tl="$(tabs_of_handle "${!v}")"
  fi
  [ -z "$tl" ] || echo "$v=$tl" >> "$TABS.tmp.$$"
done
mv "$TABS.tmp.$$" "$TABS"
"$KIT/bin/orca-yaml.sh" --check || true
cat "$STATE"

# The relauncher reopens the front role once its turn ends. It is detached from this process and from its terminal (double fork + new session),
# because Orca kills the process group of a tab when it closes it.
detached_start() {  # detached_start <log> <command> [args...]
  local log="$1"; shift
  if command -v setsid >/dev/null 2>&1; then ( setsid "$@" </dev/null >>"$log" 2>&1 & )
  elif [ -x /usr/bin/perl ]; then ( /usr/bin/perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!"; exec @ARGV' "$@" </dev/null >>"$log" 2>&1 & )
  else return 1; fi
}
start_relauncher() {
  [ "$SELF_RELAUNCH" = 1 ] || return 0
  case "$WT" in id:*) ;; *)   # 'active' would be resolved by Orca when the relauncher runs, possibly in another worktree
    echo "Cannot start $FL's relauncher: this launch has no worktree id (ORCA_WORKTREE_ID is not set); run roles from another terminal of this worktree to reopen ${FL#the } with the kit's settings and its conversation."
    return 0;;
  esac
  if detached_start "$GITDIR/orca-roles-relaunch.log" "${ORCA_ROLES_RELAUNCHER:-$KIT/bin/relaunch-planner.sh}" "$WT" "$GITDIR" "$SELF_HANDLE" "$(git_here toplevel)"; then
    echo "$FLC's relauncher is waiting for its turn to end (log: $GITDIR/orca-roles-relaunch.log)."
  else
    echo "Cannot start $FL's relauncher on this system: $FL keeps working without the kit's settings; run roles from another terminal of this worktree to reopen it with them and its conversation."
  fi
}
if [ -z "$NEW" ]; then echo "All roles are already open."; start_relauncher; exit 0; fi
[ -n "$REMEMBERED" ] && echo "Resuming workspace:$REMEMBERED keep their conversation from before the restart."
[ -n "$RESUMED" ] && echo "Resuming workspace:$RESUMED start without memory; $FL will recover the previous state and give you a summary."
case " $NEW " in *" $FRONT "*) ;; *) [ "$SELF_RELAUNCH" = 1 ] || [ "$SELF_NO_SESSION" = 1 ] || [ "$PLANNER_BUSY" = 1 ] || [ "${ORCA_TERMINAL_HANDLE:-}" = "${!FRONTV:-}" ] || echo "$FLC kept its tab: it is told the new handles by a message (\"Role handles changed\"); if it does not pick them up, ask it to read its messages.";; esac
KLOG="$GITDIR/orca-roles-kickoff.log"
if [ "${ORCA_ROLES_RELAUNCH:-}" = 1 ]; then KLOG="$GITDIR/orca-roles-relaunch.log"; else [ ! -f "$KLOG" ] || mv -f "$KLOG" "$KLOG.1"; : > "$KLOG"; fi   # launched by the relauncher: its log is appended to; otherwise the previous launch's log is kept as .1
ORCA_ROLES_SWITCH_FROM="$SWITCH_FROM" ORCA_ROLES_SELF_RELAUNCH="$SELF_RELAUNCH" ORCA_ROLES_PLANNER_BUSY="$PLANNER_BUSY" ORCA_ROLES_SELF_NO_SESSION="$SELF_NO_SESSION" nohup "$KICKOFF" "$WT" "$STATE" "$CFG" "$NEW" "$RESUMED" "$REMEMBERED" "$REUSED" >> "$KLOG" 2>&1 &
mkdir -p "$KICKOFFS" && printf '%s\n' "${NEW# }" > "$KICKOFFS/$!"
echo "Role kickoff in progress (log: $KLOG)"
start_relauncher
