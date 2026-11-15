#!/usr/bin/env bash
# Assigns a task to a worker's tab and, in the background, checks that the worker started it.
# Usage:  dispatch.sh (--task <task_id> | --spec-file <file>) (--to <handle> | --role <id> [--open]) [--run <run_id>]
#         dispatch.sh --check-only --task <task_id> --to <handle>
# The first form runs `orca orchestration dispatch --task <t> --to <h> [--run <id>] --inject --json`, prints Orca's JSON unchanged and exits
# with its status at once: 3 when Orca exited 0 but its output holds no created dispatch (after the same JSON and one line on stderr); when it
# succeeded, a checker is started detached. --check-only starts only the checker (for a task delivered another way; the message goes to $ORCA_TERMINAL_HANDLE).
# Before it dispatches to a role whose agent is claude, codex or unset (or a handle that is no role) it pauses 2 s and waits up to 60 s for the tab to be idle
# (orca terminal wait --for tui-idle); an opencode role: the same pause and up to 30 s. So the brief does not land in the worker's answer to its role
# message; past that it dispatches anyway and logs one line.
# The checker (about 95 s at most, nothing printed in the caller's terminal, notes in <git dir>/orca-roles-dispatch.log): Orca's dispatch
# result cannot tell whether the turn began (the brief may stay typed but unsent in the composer), so it polls `orca worktree ps` for
# a row of the worker's pane whose prompt names the task (none for a role whose agent is neither claude nor codex): every 3 s for 45 s. If it has not started it sends Enter once, only when the
# preview of the tab shows "[Pasted text", and polls 45 s more. Still not started: one "Dispatch not started" status to the dispatcher.
#         --role <id> / --spec-file <file> / --open
# --role takes the role's handle from the team state (ORCA_ROLES_STATE, else <git dir>/orca-roles.env: the first line <VAR>=<handle>, <id> upper-cased with
# every - turned into _) instead of --to. --spec-file creates the task first with `orca orchestration task-create --spec-file <file> --task-title
# "<id or handle>: <basename>" --run <run_id> --json` and prints "dispatch.sh: task <task_id> created from <file> for <id> (<handle>)"; --open runs
# `${ORCA_ROLES_LAUNCH:-$KIT/bin/launch.sh} --open <id>` first and waits until the state holds the role's handle H and <git dir>/orca-roles.kicked the line
# <VAR>=H (every ORCA_ROLES_OPEN_TICK s, default 2, at most ORCA_ROLES_OPEN_WAIT s, default 240; it stops at once when no kickoff runs and the line is
# missing), so a refused or an unreached role leaves no task. In these forms a non-zero exit of `orca orchestration dispatch` is exit 1 (Orca's output
# printed), never Orca's own status. Exit codes: 0 dispatched, 2 usage, 3 no dispatch created by Orca, 4 no handle for the role in the state, 5
# task-create failed, 6 launch failed or the role was not reached in time.
#         dispatch.sh --mail --run <run_id>
# With --run (all three forms) a detached mail watcher of that Run also runs, one per Run (notes in orca-roles-mail.log next to the dispatch
# log): Orca sometimes never types its "You have N orchestration message" notice. Every 15 s it reads the Run's mailbox; a message that is
# 20 s old, not delivered and not read gets one notice typed into the Run's coordinator tab, only when that tab is a Claude agent at rest
# (turn ended 5 s ago or more, not interrupted, not waiting) with an empty composer. Each message is noticed at most once. It ends when the
# Run has no open dispatch, no hidden run in flight and no such message, or 4 h after the last start request.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
GITDIR="$(git rev-parse --git-dir 2>/dev/null)" && GITDIR="$(cd "$GITDIR" && pwd)" || GITDIR=""
if [ -n "$GITDIR" ]; then LOG="$GITDIR/orca-roles-dispatch.log"; else mkdir -p "$KIT/tmp" 2>/dev/null; LOG="$KIT/tmp/orca-roles-dispatch.log"; fi   # outside a repository nothing is left in the current folder
TICK="${ORCA_ROLES_DISPATCH_TICK:-3}"; POLLS="${ORCA_ROLES_DISPATCH_POLLS:-15}"   # seconds between polls, polls per wait (the tests shorten them)
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
# Usage metrics (settings.metrics): one events.jsonl line per step of a dispatch. One config read: this worktree's saved copy, else the global one.
MCFG="${GITDIR:+$GITDIR/orca-roles.config.json}"; [ -f "$MCFG" ] || { MCFG="$KIT/config.json"; [ -f "$MCFG" ] || MCFG="$KIT/config.default.json"; }
METRICS=0; metrics_enabled "$MCFG" && METRICS=1
MTOP=""; if [ -n "$GITDIR" ] && MTOP="$(git rev-parse --show-toplevel 2>/dev/null)"; then MTOP="$(cd "$MTOP" && pwd -P)"; else MTOP=""; fi
mevent() {  # mevent <event> <task> <handle>
  local id="" b
  [ "$METRICS" = 1 ] || return 0
  id="$(role_of_handle "$3")"
  [ -n "$id" ] && { b="$(instance_base "$MCFG" "$id")"; id="${b:-$id}"; }
  metrics_event "$MTOP" "$1" "$id" "$2"
}
role_of_handle() {  # role_of_handle <handle>: the role id that owns it in the team state, or nothing
  local var state="${ORCA_ROLES_STATE:-${GITDIR:+$GITDIR/orca-roles.env}}"
  [ -n "$state" ] && [ -f "$state" ] || return 0
  var="$(grep -m1 "=$1\$" "$state" 2>/dev/null | cut -d= -f1)"; [ -n "$var" ] || return 0
  printf '%s' "$var" | tr 'A-Z_' 'a-z-'
}
role_var() {  # role_var <id>: the team state's variable for that role id (var_of's inverse)
  printf '%s' "$1" | tr '-' '_' | tr '[:lower:]' '[:upper:]'
}
state_value() {  # state_value <file> <VAR>: the value of the first <VAR>=<line> line of that file, or nothing
  [ -n "$1" ] && [ -f "$1" ] || return 0
  awk -v v="$2" 'index($0, v "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null
}
handle_of_var() { local st; st="${ORCA_ROLES_STATE:-${GITDIR:+$GITDIR/orca-roles.env}}"; state_value "$st" "$1"; }   # handle_of_var <VAR>: the role's handle in the team state
kicked_of_var() { [ -n "$GITDIR" ] || return 0; state_value "$GITDIR/orca-roles.kicked" "$1"; }   # kicked_of_var <VAR>: its handle in orca-roles.kicked, written with its role message (kickoff.sh:7)
role_ready() { local h; h="$(handle_of_var "$1")"; [ -n "$h" ] && [ "$(kicked_of_var "$1")" = "$h" ]; }   # role_ready <VAR>: the state has its handle and the kicked line holds the same one
kickoff_live() {  # a kickoff is running: a file in <git dir>/orca-roles.kickoff.d named by a live pid
  local f
  [ -n "$GITDIR" ] && [ -d "$GITDIR/orca-roles.kickoff.d" ] || return 1
  for f in "$GITDIR/orca-roles.kickoff.d"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in ''|*[!0-9]*) continue;; esac
    kill -0 "${f##*/}" 2>/dev/null && return 0
  done
  return 1
}
open_wait() {  # open_wait <id> <VAR>: waits for the role message of a role just opened to be sent
  local tick wait n i=0
  role_ready "$2" && return 0
  tick="$(awk -v t="${ORCA_ROLES_OPEN_TICK:-2}" 'BEGIN { if (t + 0 <= 0) t = 2; print t }')"
  wait="${ORCA_ROLES_OPEN_WAIT:-240}"; case "$wait" in ''|*[!0-9.]*) wait=240;; esac
  n="$(awk -v w="$wait" -v t="$tick" 'BEGIN { k = int(w / t); if (k < 0) k = 0; print k }')"
  while :; do
    kickoff_live || { echo "dispatch.sh: $1 was not reached (no role message sent); nothing created or dispatched." >&2; exit 6; }
    [ "$i" -lt "$n" ] || { echo "dispatch.sh: $1 is not ready after $wait s; nothing created or dispatched. Dispatch once \"Roles reopened\" names it." >&2; exit 6; }
    sleep "$tick"; i=$((i + 1))
    role_ready "$2" && return 0
  done
}

# Same detachment as launch.sh's detached_start: Orca kills the process group of a tab when it closes it.
detached_start() {  # detached_start <log> <command> [args...]
  local out="$1"; shift
  if command -v setsid >/dev/null 2>&1; then ( setsid "$@" </dev/null >>"$out" 2>&1 & )
  elif [ -x /usr/bin/perl ]; then ( /usr/bin/perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!"; exec @ARGV' "$@" </dev/null >>"$out" 2>&1 & )
  else return 1; fi
}

# The agent of the role in the team state that owns <handle>, when it is neither claude nor codex: Orca may have no worktree-ps row for such a tab.
other_agent_of() {  # other_agent_of <handle>
  local var id ag state="${ORCA_ROLES_STATE:-${GITDIR:+$GITDIR/orca-roles.env}}" cfg="${ORCA_ROLES_CONFIG:-${GITDIR:+$GITDIR/orca-roles.config.json}}"
  [ -n "$state" ] && [ -n "$cfg" ] && [ -f "$state" ] && [ -f "$cfg" ] || return 1
  var="$(grep -m1 "=$1\$" "$state" 2>/dev/null | cut -d= -f1)"; [ -n "$var" ] || return 1
  id="$(printf '%s' "$var" | tr 'A-Z_' 'a-z-')"
  ag="$(rstr "$cfg" "$id" agent 2>/dev/null)"
  case "$ag" in ''|claude|codex) return 1;; esac
  printf '%s' "$ag"
}
start_checker() {  # start_checker <task> <handle> <pane key> <dispatcher handle>
  local ag
  if ag="$(other_agent_of "$2")"; then log "$2: no start check for agent $ag"; mevent no-check "$1" "$2"; return 0; fi
  detached_start "$LOG" "$SELF" --watch "$1" "$2" "$3" "$4" || log "$2: $1 not checked (no way to detach the checker)"
}
started() {  # started <pane key> <task id>: Orca has a row for that pane whose prompt names the task
  orca worktree ps --json 2>/dev/null | jq -e --arg p "$1" --arg t "$2" 'any(.result.worktrees[]?.agents[]?; .paneKey == $p and ((.prompt // "") | contains($t)))' >/dev/null 2>&1
}
wait_started() {  # wait_started <pane key> <task id>: polls POLLS times, TICK seconds apart
  local i
  for ((i = 0; i < POLLS; i++)); do
    started "$1" "$2" && return 0
    sleep "$TICK"
  done
  return 1
}

# The mail watcher: one per Run, its files next to the dispatch log
MDIR="${LOG%/*}"; MLOG="$MDIR/orca-roles-mail.log"; MRUN=""
MTICK="${ORCA_ROLES_MAIL_TICK:-15}"; MGRACE="${ORCA_ROLES_MAIL_GRACE:-20}"; MMAX="${ORCA_ROLES_MAIL_MAX:-14400}"   # seconds between looks, age before a message counts as not announced, life after the last start request (the tests shorten them)
mlog() { printf '%s mail %s: %s\n' "$(date '+%F %T')" "$MRUN" "$*" >> "$MLOG"; }
valid_run() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1;; esac; }
num_or_0() { case "$1" in ''|*[!0-9]*) echo 0;; *) echo "$1";; esac; }
start_mail() {  # start_mail <run>: records the request and starts the Run's watcher unless one is alive
  local p ps
  valid_run "$1" || return 0
  date +%s > "$MDIR/orca-roles-mail.$1.req" 2>/dev/null || return 0
  { read -r p ps _ < "$MDIR/orca-roles-mail.$1.pid"; } 2>/dev/null
  proc_is "${p:-}" "${ps:--}" && return 0
  detached_start "$MLOG" "$SELF" --mail-watch "$1" || { MRUN="$1"; mlog "not started (no way to detach the watcher)"; }
}
in_flight() {  # the Run has an open dispatch, or a hidden run is in flight in this worktree; also true when Orca does not answer
  local f wl
  if [ -n "$GITDIR" ]; then
    for f in "$GITDIR/orca-roles-hidden/"*.pid; do
      [ -e "$f" ] || continue
      f="${f##*/}"; hidden_live "$GITDIR" "${f%.pid}" && return 0
    done
  fi
  wl="$(orca orchestration worker-list --run "$MRUN" --json --full 2>/dev/null)"
  printf '%s' "$wl" | jq -e '.result.workers | type == "array"' >/dev/null 2>&1 || return 0
  printf '%s' "$wl" | jq -e 'any(.result.workers[]; (.dispatchStatus // "completed") | IN("completed", "failed", "cancelled", "abandoned", "released") | not)' >/dev/null 2>&1
}
coord_ready() {  # sets CH to the Run's coordinator handle; true when its tab is a Claude agent at rest with an empty composer, else sets WHY
  local ts pane row
  WHY=""
  CH="$(orca orchestration run-show --id "$MRUN" --json --full 2>/dev/null | jq -r '.result.run.coordinator_handle // empty' 2>/dev/null)"
  [ -n "$CH" ] || { WHY="no coordinator handle"; return 1; }
  ts="$(orca terminal show --terminal "$CH" --json 2>/dev/null)"
  [ "$(printf '%s' "$ts" | jq -r '.result.terminal.agentIdentity // empty' 2>/dev/null)" = claude ] || { WHY="not a Claude tab"; return 1; }
  printf '%s' "$ts" | jq -e '.result.terminal | .orphaned != true and .writable != false' >/dev/null 2>&1 || { WHY="tab not writable"; return 1; }
  pane="$(printf '%s' "$ts" | jq -r '.result.terminal | select(.tabId != null and .leafId != null) | "\(.tabId):\(.leafId)"' 2>/dev/null)"
  [ -n "$pane" ] || { WHY="no pane"; return 1; }
  printf '%s' "$ts" | jq -e '(.result.terminal.preview // "") as $p | ($p | contains("[Pasted text") | not) and ($p | split("\n") | any(sub("\\s+$"; "") == "❯"))' >/dev/null 2>&1 || { WHY="composer not empty"; return 1; }
  row="$(orca worktree ps --json 2>/dev/null | jq -c --arg p "$pane" '[.result.worktrees[]?.agents[]? | select(.paneKey == $p)] | sort_by(.updatedAt // 0) | last // empty' 2>/dev/null)"
  [ -n "$row" ] || { WHY="no status"; return 1; }
  printf '%s' "$row" | jq -e --argjson now "$(( $(date +%s) * 1000 ))" '((.mainAgent.state // .state) == "done") and (.interrupted != true) and (($now - ((.mainAgent.stateStartedAt // .stateStartedAt) // $now)) >= 5000)' >/dev/null 2>&1 || { WHY="not at rest"; return 1; }
}

if [ "${1:-}" = --mail-watch ]; then   # hidden: the detached mail watcher  --mail-watch <run>
  MRUN="${2:-}"; valid_run "$MRUN" || exit 0
  LK="$MDIR/orca-roles-mail.$MRUN.pid"; REQ="$MDIR/orca-roles-mail.$MRUN.req"; SEEN="$MDIR/orca-roles-mail.$MRUN.noticed"
  # the pid file "<pid> <start>" is the lock (created with noclobber): its live process (proc_is: a reused pid does not count), or an empty file younger than a minute (a watcher starting), keeps it
  ME="$$ $(proc_start $$)"
  if ! ( set -o noclobber; echo "$ME" > "$LK" ) 2>/dev/null; then
    p=""; ps=""; read -r p ps _ < "$LK" 2>/dev/null
    if [ -z "$p" ]; then [ -z "$(find "$LK" -mmin -1 2>/dev/null)" ] || exit 0; else proc_is "$p" "${ps:--}" && exit 0; fi
    rm -f "$LK"; ( set -o noclobber; echo "$ME" > "$LK" ) 2>/dev/null || exit 0
  fi
  trap '[ "$(cat "$LK" 2>/dev/null)" != "$ME" ] || rm -f "$LK"' EXIT
  # mquit <second> <why>: ends; a start request written from that second on (it found this watcher still alive, so it started none) gets a new watcher once the lock is free
  mquit() { mlog "$2"; rm -f "$LK"; [ "$(num_or_0 "$(cat "$REQ" 2>/dev/null)")" -lt "$1" ] || { mlog "restarted: a new start request"; start_mail "$MRUN"; }; exit 0; }
  T0="$(date +%s)"; FAILS=0; SENDFAILS=0; LAST=""
  mlog "started"
  while :; do
    NOW="$(date +%s)"
    INB="$(orca orchestration inbox --terminal "run:$MRUN" --limit 50 --full --json 2>/dev/null)"
    if printf '%s' "$INB" | jq -e '.result.messages | type == "array"' >/dev/null 2>&1; then
      FAILS=0
      SEENJ="$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$SEEN" 2>/dev/null)" || SEENJ='[]'; [ -n "$SEENJ" ] || SEENJ='[]'
      PEND="$(printf '%s' "$INB" | jq -c --arg to "run:$MRUN" --argjson seen "$SEENJ" --argjson now "$NOW" --argjson grace "$MGRACE" '[.result.messages[] | select(.to_handle == $to and .delivered_at == null and (.read // 0) == 0 and (.id as $i | $seen | index($i) | not)) | {id, due: (($now - ((.created_at // "") | fromdateiso8601? // 0)) >= $grace)}]' 2>/dev/null)" || PEND='[]'
      DUE="$(printf '%s' "$PEND" | jq -r '.[] | select(.due) | .id' 2>/dev/null)"
      if [ -n "$DUE" ]; then
        N="$(printf '%s\n' "$DUE" | wc -l | tr -d ' ')"; IDS="$(printf '%s' "$DUE" | tr '\n' ' ')"
        if coord_ready; then
          if orca terminal send --terminal "$CH" --text "You have $N unread orchestration message(s) that Orca did not announce. Run \`~/.orca-roles/bin/inbox.sh --run $MRUN\`." --enter --json >/dev/null 2>&1; then
            printf '%s\n' "$DUE" >> "$SEEN"; tail -n 200 "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
            mlog "noticed $N ($IDS) to $CH"; SENDFAILS=0; LAST=""
          else
            SENDFAILS=$((SENDFAILS + 1)); mlog "notice to $CH failed ($SENDFAILS)"
            if [ "$SENDFAILS" -ge 3 ]; then printf '%s\n' "$DUE" >> "$SEEN"; mlog "gave up on $IDS"; SENDFAILS=0; fi
          fi
        elif [ "$IDS:$WHY" != "$LAST" ]; then
          mlog "not announced: $IDS; no notice yet: $WHY"; LAST="$IDS:$WHY"
        fi
      fi
      if [ "$(printf '%s' "$PEND" | jq 'length' 2>/dev/null)" = 0 ] && ! in_flight && [ "$(num_or_0 "$(cat "$REQ" 2>/dev/null)")" -lt "$NOW" ]; then
        mquit "$NOW" "ended: no task in flight"
      fi
    else
      FAILS=$((FAILS + 1))
      [ "$FAILS" -lt 20 ] || { mlog "ended: Orca did not answer 20 times"; exit 0; }
    fi
    RT="$(date +%s)"; BASE="$(num_or_0 "$(cat "$REQ" 2>/dev/null)")"; [ "$BASE" -gt "$T0" ] || BASE="$T0"
    [ "$(date +%s)" -lt $((BASE + MMAX)) ] || mquit "$RT" "ended: time limit"
    sleep "$MTICK"
  done
fi

if [ "${1:-}" = --watch ]; then   # hidden: the detached checker  --watch <task> <handle> <pane key> <dispatcher handle>
  task="$2"; h="$3"; pane="$4"; creator="$5"; enter=no; t0=$SECONDS
  if [ -z "$pane" ]; then log "$h: $task not checked (no pane key for it)"; exit 0; fi
  wait_started "$pane" "$task" && { log "$h: $task started"; mevent started "$task" "$h"; exit 0; }
  if orca terminal show --terminal "$h" --json 2>/dev/null | jq -e '.result.terminal.preview // "" | contains("[Pasted text")' >/dev/null 2>&1; then
    if orca terminal send --terminal "$h" --enter --json >/dev/null 2>&1; then enter=yes; log "$h: $task unsent in its composer; Enter re-sent"; mevent enter-resent "$task" "$h"; fi
    if [ "$enter" = yes ] && wait_started "$pane" "$task"; then log "$h: Enter re-sent, task started"; mevent started "$task" "$h"; exit 0; fi
  fi
  body="$h has not started $task after $((SECONDS - t0)) s (Enter re-sent: $enter). Look at its tab or tell the user."
  if [ -n "$creator" ] && orca orchestration send --to "$creator" --type status --subject "Dispatch not started" --body "$body" --json >/dev/null 2>&1; then
    log "$h: $task not started (Enter re-sent: $enter); told $creator"
  else
    log "$h: $task not started (Enter re-sent: $enter); could not tell the dispatcher"
  fi
  mevent not-started "$task" "$h"
  exit 0
fi

TASK=""; TO=""; RUN=""; ROLE=""; SPEC=""; ONLY=0; OPEN=0
USAGE="Usage: dispatch.sh (--task <task_id> | --spec-file <file>) (--to <handle> | --role <id> [--open]) [--run <run_id>] | --check-only --task <task_id> --to <handle> [--run <run_id>] | --mail --run <run_id>"
usage() { echo "$USAGE" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --task) [ -n "${2:-}" ] || usage; TASK="$2"; shift;;
    --to) [ -n "${2:-}" ] || usage; TO="$2"; shift;;
    --run) RUN="${2:-}"; shift;;
    --role) [ -n "${2:-}" ] || usage; ROLE="$2"; shift;;
    --spec-file) [ -n "${2:-}" ] || usage; SPEC="$2"; shift;;
    --open) OPEN=1;;
    --check-only) ONLY=1;;
    --mail) ONLY=2;;
    *) echo "dispatch.sh: unknown option $1" >&2; exit 2;;
  esac
  shift
done
if [ "$ONLY" = 2 ]; then
  [ -z "$ROLE$SPEC" ] && [ "$OPEN" = 0 ] || usage
  valid_run "$RUN" || usage
  start_mail "$RUN"
  exit 0
fi
if [ "$ONLY" = 1 ]; then
  [ -z "$ROLE$SPEC" ] && [ "$OPEN" = 0 ] || usage
  [ -n "$TASK" ] && [ -n "$TO" ] || usage
  pane="$(orca terminal show --terminal "$TO" --json 2>/dev/null | jq -r '.result.terminal | select(.tabId != null and .leafId != null) | "\(.tabId):\(.leafId)"' 2>/dev/null)"
  creator="${ORCA_TERMINAL_HANDLE:-}"
  start_checker "$TASK" "$TO" "$pane" "$creator"
  [ -z "$RUN" ] || start_mail "$RUN"
  exit 0
fi
# exactly one target (--to or --role) and one task (--task or --spec-file); --spec-file needs its Run and --open a role
{ [ -n "$TO" ] && [ -n "$ROLE" ]; } && usage
[ -n "$TO" ] || [ -n "$ROLE" ] || usage
{ [ -n "$TASK" ] && [ -n "$SPEC" ]; } && usage
[ -n "$TASK" ] || [ -n "$SPEC" ] || usage
[ -z "$SPEC" ] || [ -n "$RUN" ] || usage
[ "$OPEN" = 0 ] || [ -n "$ROLE" ] || usage
[ -z "$SPEC" ] || { [ -f "$SPEC" ] && [ -r "$SPEC" ]; } || usage
NEW=0
if [ -n "$ROLE" ] || [ -n "$SPEC" ]; then NEW=1; fi
# --open opens the role before the handle is read and before any task is created: a refused or unreached role leaves no task behind
if [ "$OPEN" = 1 ]; then
  "${ORCA_ROLES_LAUNCH:-$KIT/bin/launch.sh}" --open "$ROLE"
  LRC=$?
  [ "$LRC" = 0 ] || { echo "dispatch.sh: launch.sh --open $ROLE failed (exit $LRC); nothing created or dispatched." >&2; exit 6; }
  open_wait "$ROLE" "$(role_var "$ROLE")"
fi
if [ -n "$ROLE" ]; then
  TO="$(handle_of_var "$(role_var "$ROLE")")"
  [ -n "$TO" ] || { echo "dispatch.sh: no handle for role $ROLE in the team state; open it with --open." >&2; exit 4; }
fi
if [ -n "$SPEC" ]; then
  SBASE="$(basename "$SPEC")"
  if [ -n "$ROLE" ]; then STITLE="$ROLE: $SBASE"; else STITLE="$TO: $SBASE"; fi
  TC_OUT="$(orca orchestration task-create --spec-file "$SPEC" --task-title "$STITLE" --run "$RUN" --json)"
  TC_RC=$?
  TASK="$(printf '%s' "$TC_OUT" | jq -r 'select(.ok == true and .result.status == "ready") | (.result.taskId // "") | select(type == "string" and length > 0)' 2>/dev/null)"
  if [ "$TC_RC" != 0 ] || [ -z "$TASK" ]; then
    [ -z "$TC_OUT" ] || printf '%s\n' "$TC_OUT" >&2
    echo "dispatch.sh: task-create failed for $SPEC; nothing dispatched." >&2
    exit 5
  fi
  if [ -n "$ROLE" ]; then printf 'dispatch.sh: task %s created from %s for %s (%s)\n' "$TASK" "$SPEC" "$ROLE" "$TO"
  else printf 'dispatch.sh: task %s created from %s for %s\n' "$TASK" "$SPEC" "$TO"; fi
fi

# A brief typed while the worker is still answering (its role message, just resent by clean.sh or launch.sh) arrives in that turn; Orca reads the turn's end as the worker stopping without reporting
if ag="$(other_agent_of "$TO")"; then
  # opencode: the same pause and one wait of at most 30 s (`opencode mini` tabs never report idle after their first turn, as clean.sh notes); any other agent: no wait
  if [ "$ag" = opencode ]; then
    pace 2
    orca terminal wait --terminal "$TO" --for tui-idle --timeout-ms 30000 --json >/dev/null 2>&1 || log "$TO: not idle within 30 s (or the wait failed); dispatching $TASK anyway"
  fi
else
  # claude, codex, an unset agent, a handle that is no role
  pace 2   # a role message typed just before has begun its turn, so the wait does not read the tab as idle before it (as kickoff.sh's check_model does)
  orca terminal wait --terminal "$TO" --for tui-idle --timeout-ms 60000 --json >/dev/null 2>&1 || log "$TO: not idle within 60 s (or the wait failed); dispatching $TASK anyway"
fi
args=(orchestration dispatch --task "$TASK" --to "$TO")
[ -z "$RUN" ] || args+=(--run "$RUN")
OUT="$(orca "${args[@]}" --inject --json)"; rc=$?
printf '%s\n' "$OUT"
if [ "$rc" = 0 ]; then
  # Created: Orca exited 0, ok is true and its dispatch holds a non-empty string id (.result.dispatch when the key is there, else .result); anything else is not a dispatch
  if ! printf '%s' "$OUT" | jq -e '.ok == true and ((if (.result | type) == "object" and (.result | has("dispatch")) then .result.dispatch else .result end) | (type == "object") and ((.id // "") | (type == "string") and (length > 0)))' >/dev/null 2>&1; then
    echo "dispatch.sh: no dispatch was created for $TASK on $TO (orca exited 0); see Orca's output above." >&2
    exit 3
  fi
  mevent dispatch "$TASK" "$TO"
  pane="$(printf '%s' "$OUT" | jq -r '(.result.dispatch // .result // {}) | .assignee_pane_key // empty' 2>/dev/null)"
  creator="$(printf '%s' "$OUT" | jq -r '(.result.dispatch // .result // {}) | .creator_handle // empty' 2>/dev/null)"
  start_checker "$TASK" "$TO" "$pane" "${creator:-${ORCA_TERMINAL_HANDLE:-}}"
  [ -z "$RUN" ] || start_mail "$RUN"
fi
if [ "$rc" != 0 ] && [ "$NEW" = 1 ]; then exit 1; fi
exit "$rc"
