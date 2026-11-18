#!/usr/bin/env bash
# Reopens the lost or unconfigured role tabs of the coordinated worktrees a coordinator opened, one worktree at a time: for each one it runs
# 'launch.sh id:<worktree id> --reopen' in that worktree's folder and keeps the outcome in its summary. Main checkouts, worktrees without a
# coordinator marker, without a valid Run id, without a team state and with no mode chosen yet are skipped (and said so in the log).
# With --coordinator (or, without it, from a coordinator's own session) only the worktrees whose marker Run is bound to one of those handles
# are reopened; the others are logged 'other-coordinator'. A worktree whose Run is bound to no tab and that nothing records as that
# coordinator's is logged 'unbound-run' and named in the summary: a Run released by a run-use other than the SessionStart hook's one, in a
# worktree whose kickoff could not write the owner line (a worktree started before this version); 'launch.sh --reopen' in that worktree, or
# this script from a person's terminal (unscoped), reopens it.
# Usage: reopen-teams.sh [--detach] [--coordinator <handle>]...     (--detach: run it in the background, print the log path and return)
# Log: ~/.orca-roles/state/reopen-teams.log (its last 500 lines are kept). Summary: printed, appended to the log and written (replaced) to
# ~/.orca-roles/state/reopen-teams.last, and sent as one status "Teams reopened" to ORCA_TERMINAL_HANDLE when that is set. A run that ends
# before it writes its result (a signal, an error) replaces its own "Reopen running" line with "Reopen stopped before it finished (pid N)".
# Exit: 0 no worktree failed; 1 one or more failed; 2 usage error or Orca did not answer; 3 --detach cannot detach.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"
STATE="$KIT/state"
LOG="$STATE/reopen-teams.log"
SUMMARY_FILE="$STATE/reopen-teams.last"
LOCK="$STATE/reopen-teams.lock"
DETACH=0
DETACHED="${ORCA_ROLES_REOPEN_DETACHED:-0}"

# Detached from this process and from its terminal (new session), because Orca kills the process group of a tab when it closes it.
detached_start() {  # detached_start <log> <command> [args...]
  local out="$1"; shift
  if command -v setsid >/dev/null 2>&1; then ( setsid "$@" </dev/null >>"$out" 2>&1 & )
  elif [ -x /usr/bin/perl ]; then ( /usr/bin/perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!"; exec @ARGV' "$@" </dev/null >>"$out" 2>&1 & )
  else return 1; fi
}

usage() { echo "Usage: reopen-teams.sh [--detach] [--coordinator <handle>]..." >&2; exit 2; }
valid_handle() { [ -n "${1:-}" ] || return 1; case "$1" in *[!A-Za-z0-9_-]*) return 1;; esac; return 0; }
add_coordinator() {  # add_coordinator <handle>: a repeated handle is kept once, in the order given
  local h
  valid_handle "$1" || usage
  for h in ${COORDINATORS[@]+"${COORDINATORS[@]}"}; do [ "$h" = "$1" ] && return 0; done
  COORDINATORS+=("$1")
}
COORDINATORS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n 2,14p "$0" 2>/dev/null || true; exit 0;;
    --detach) DETACH=1; shift;;
    --coordinator) shift; [ $# -gt 0 ] || usage; add_coordinator "$1"; shift;;
    *) usage;;
  esac
done
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/$(basename "$0")"

if [ "$DETACH" = 1 ]; then
  mkdir -p "$STATE" 2>/dev/null || { echo "reopen-teams.sh: cannot write in $STATE; nothing was started." >&2; exit 3; }
  CARGS=()
  for h in ${COORDINATORS[@]+"${COORDINATORS[@]}"}; do CARGS+=(--coordinator "$h"); done
  detached_start "$LOG" env ORCA_ROLES_REOPEN_DETACHED=1 "$SELF" ${CARGS[@]+"${CARGS[@]}"} \
    || { echo "reopen-teams.sh: cannot run in the background on this system (no setsid and no /usr/bin/perl); nothing was started." >&2; exit 3; }
  echo "reopen-teams.sh: reopening the teams in the background (log: $LOG)."
  exit 0
fi

# shellcheck source=/dev/null
. "$KIT/bin/lib.sh" 2>/dev/null || { echo "reopen-teams.sh: cannot read $KIT/bin/lib.sh." >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "reopen-teams.sh: jq is not on the PATH." >&2; exit 2; }
mkdir -p "$STATE" 2>/dev/null || { echo "reopen-teams.sh: cannot write in $STATE." >&2; exit 2; }

TRIES="${ORCA_ROLES_REOPEN_TRIES:-3}"
PAUSE="${ORCA_ROLES_REOPEN_PAUSE:-20}"
WAIT="${ORCA_ROLES_REOPEN_WAIT:-120}"
LAUNCH_MAX="${ORCA_ROLES_REOPEN_LAUNCH_MAX:-300}"
case "$TRIES" in ''|*[!0-9]*) TRIES=3;; esac; [ "$TRIES" -ge 1 ] || TRIES=1
case "$PAUSE" in ''|*[!0-9]*) PAUSE=20;; esac
case "$WAIT" in ''|*[!0-9]*) WAIT=120;; esac
case "$LAUNCH_MAX" in ''|*[!0-9]*) LAUNCH_MAX=300;; esac; [ "$LAUNCH_MAX" -ge 1 ] || LAUNCH_MAX=300
TRY_OUT="$STATE/reopen-teams.try.$$"

# The scope: the handles given with --coordinator, or a coordinator's own handle when this runs from its session; none = every worktree.
GIVEN=""
for h in ${COORDINATORS[@]+"${COORDINATORS[@]}"}; do GIVEN="${GIVEN:+$GIVEN }$h"; done
if [ -z "$GIVEN" ] && [ "${ORCA_ROLES_SESSION_KIND:-}" = coordinator ] && valid_handle "${ORCA_TERMINAL_HANDLE:-}"; then
  GIVEN="$ORCA_TERMINAL_HANDLE"
fi
SCOPE=0
[ -z "$GIVEN" ] || SCOPE=1

# say: one line in the log and, in the foreground, on the terminal; a detached run prints to the log itself (its stdout is appended to it)
say() { [ "$DETACHED" = 1 ] && { printf '%s\n' "$*"; return 0; }; printf '%s\n' "$*"; printf '%s\n' "$*" >> "$LOG"; }
slog() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
already_running() { echo "reopen-teams.sh is already running (pid $1); nothing to do."; exit 0; }

# One run at a time: the lock directory is created atomically and holds the run's pid; a lock whose pid is gone is taken over.
lock_pid() { head -n 1 "$LOCK/pid" 2>/dev/null; }
take_lock() {
  local p
  mkdir "$LOCK" 2>/dev/null && return 0
  p="$(lock_pid)"
  case "$p" in ''|*[!0-9]*) ;; *) kill -0 "$p" 2>/dev/null && return 1;; esac
  slog "the lock of pid ${p:-none} is gone: taken over"
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null
}
trim_log() { [ -s "$LOG" ] && tail -n 500 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG" 2>/dev/null; return 0; }
if ! take_lock; then already_running "$(lock_pid)"; fi
echo $$ > "$LOCK/pid" 2>/dev/null
# At the end of every run (also one that exits 1, 2, or by a signal or an error): the log keeps its last 500 lines, the lock and the try
# output go, and a summary that still holds this run's own "Reopen running" line gets the stopped line and the outcomes written so far.
finish_run() {  # finish_run <status>
  local st="$1" first="" rest=""
  { read -r first < "$SUMMARY_FILE"; } 2>/dev/null || true
  case "$first" in *"Reopen running (pid $$); the result replaces this line."*)
    rest=""; [ -z "${SUMMARY:-}" ] || rest="$(printf '%s\n' "$SUMMARY" | sed -n '2,$p')"
    printf '%s Reopen stopped before it finished (pid %s); run ~/.orca-roles/bin/reopen-teams.sh --detach again.\n' "$(date '+%F %T')" "$$" > "$SUMMARY_FILE"
    [ -z "$rest" ] || printf '%s\n' "$rest" >> "$SUMMARY_FILE";;
  esac
  rm -f "$TRY_OUT" 2>/dev/null; trim_log; rm -rf "$LOCK"
  exit "$st"
}
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'finish_run $?' EXIT

printf '%s Reopen running (pid %s); the result replaces this line.\n' "$(date '+%F %T')" "$$" > "$SUMMARY_FILE"
if [ "$SCOPE" = 1 ]; then
  say "Scope: the worktrees whose Run is bound to $(printf '%s' "$GIVEN" | sed 's/ /, /g')"
else
  say "Scope: every coordinated worktree"
fi

# The run ends before its work when Orca does not answer or gives no list: the summary says so and the exit status is 2.
abort_run() {
  printf '%s\n' "$1" > "$SUMMARY_FILE"
  say "$1"
  exit 2
}
orca_ok() {
  local out
  out="$(bounded_run --quiet 15 "orca status (no answer from Orca)" command orca status --json 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e '.ok == true' >/dev/null 2>&1
}
wait_orca() {  # orca status answering .ok == true, looked at every 5 s, for at most WAIT seconds
  local end rem
  end=$(( $(date +%s) + WAIT ))
  while :; do
    orca_ok && return 0
    rem=$(( end - $(date +%s) ))
    [ "$rem" -ge 1 ] || return 1
    [ "$rem" -le 5 ] || rem=5
    sleep "$rem"
  done
}
wait_orca || abort_run "Orca did not answer within $WAIT s; no team was reopened."

LIST="$(orca worktree list --limit 1000 --json 2>/dev/null)" || abort_run "could not list Orca's worktrees; no team was reopened."
printf '%s' "$LIST" | jq -e '.result.worktrees | type == "array"' >/dev/null 2>&1 || abort_run "could not list Orca's worktrees; no team was reopened."
TRUNC=0; [ "$(printf '%s' "$LIST" | jq -r '.result.truncated == true')" = true ] && TRUNC=1

# Selection (D2): every worktree whose folder exists, whose git dir holds a valid orca-roles.coordinator and a non-empty orca-roles.env, with
# no orca-roles.mode-pending; never the main checkout. Rows with the same path are one worktree (the first row's id).
IDS=(); DIRS=(); RIDS=(); GDS=()
SEEN_PATHS="
"
path_seen() { case "$SEEN_PATHS" in *"
$1
"*) return 0;; esac; return 1; }
mark_path() { SEEN_PATHS="$SEEN_PATHS$1
"; }
valid_run() { case "$1" in run_?*) case "$1" in *[!A-Za-z0-9_]*) return 1;; esac; return 0;; esac; return 1; }
add_row() {
  local id="$1" p="$2" r="$3" g="$4"
  mark_path "$p"
  IDS+=("$id"); DIRS+=("$p"); RIDS+=("$r"); GDS+=("$g")
}
while IFS="$(printf '\t')" read -r id path main; do
  [ -n "$id" ] && [ -n "$path" ] || continue
  [ "$main" = true ] && continue
  path="$(local_path "$path")"
  path_seen "$path" && continue
  if [ ! -d "$path" ]; then say "$path: path-missing"; mark_path "$path"; continue; fi
  gd="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)"
  [ -n "$gd" ] && [ -f "$gd/orca-roles.coordinator" ] || continue
  run="$(head -n 1 "$gd/orca-roles.coordinator" 2>/dev/null)"
  if ! valid_run "${run:-}"; then say "$path: invalid-run"; mark_path "$path"; continue; fi
  if [ ! -s "$gd/orca-roles.env" ]; then say "$path: no-team"; mark_path "$path"; continue; fi
  if [ -e "$gd/orca-roles.mode-pending" ]; then say "$path: mode-pending"; mark_path "$path"; continue; fi
  add_row "$id" "$path" "$run" "$gd"
done <<EOF
$(printf '%s' "$LIST" | jq -r '(.result.worktrees // [])[] | [(.id // ""), (.path // ""), (if .isMainWorktree == true then "true" else "false" end)] | @tsv' 2>/dev/null)
EOF

REOPENED=0; NOTHING=0; FAILED=0; SELECTED=0
SUMMARY="$(date '+%F %T')"
if [ "$TRUNC" = 1 ]; then
  SUMMARY="$SUMMARY
Orca's worktree list was cut short: worktrees past the first 1000 were not looked at."
fi
N="${#IDS[@]}"
if [ "$SCOPE" = 0 ]; then
  [ "$N" -gt 0 ] || SUMMARY="$SUMMARY
No coordinated worktree has a team to reopen."
fi

# The scope's sessions and handles (D3): H starts as the given handles; a coordinator session whose line 1 or .handles file holds a handle of
# H joins, and its line 1 and .handles lines join H, until nothing joins (a /clear starts a new session id on the same handle, so a
# coordinator's sessions chain through the handles they share). Sessions join only through a handle they share, so the closure stays within
# one coordinator's tabs. Runs recorded in the .runs files of those sessions are read after every Run's run-show answered, never before: the
# SessionStart hook may write a .runs file while this run goes from one worktree to the next, and the Runs it adds there must count.
SESSIONS=""; CAPTURED=""; SCOPE_HANDLES=""
in_set() { case " $2 " in *" $1 "*) return 0;; esac; return 1; }
add_scope_handle() { in_set "$1" "$SCOPE_HANDLES" || SCOPE_HANDLES="${SCOPE_HANDLES:+$SCOPE_HANDLES }$1"; }
read_scope() {  # recomputed after each run-show, so a .runs file written meanwhile is seen
  SESSIONS=""; CAPTURED=""; SCOPE_HANDLES="$GIVEN"
  local changed=1 f sid l1 line join s
  while [ "$changed" = 1 ]; do
    changed=0
    for f in "$STATE/session-handles"/*; do
      [ -f "$f" ] || continue
      sid="${f##*/}"
      case "$sid" in *.*) continue;; esac
      printf '%s' "$sid" | grep -Eq '^[A-Za-z0-9-]{1,64}$' || continue
      in_set "$sid" "$SESSIONS" && continue
      [ "$(sed -n 2p "$f" 2>/dev/null)" = coordinator ] || continue
      l1="$(head -n 1 "$f" 2>/dev/null)"
      join=0
      if valid_handle "${l1:-}" && in_set "$l1" "$SCOPE_HANDLES"; then join=1; fi
      if [ "$join" = 0 ] && [ -f "$f.handles" ]; then
        while IFS= read -r line; do
          if valid_handle "$line" && in_set "$line" "$SCOPE_HANDLES"; then join=1; break; fi
        done < "$f.handles"
      fi
      [ "$join" = 1 ] || continue
      SESSIONS="${SESSIONS:+$SESSIONS }$sid"; changed=1
      if valid_handle "${l1:-}"; then add_scope_handle "$l1"; fi
      if [ -f "$f.handles" ]; then
        while IFS= read -r line; do
          if valid_handle "$line"; then add_scope_handle "$line"; fi
        done < "$f.handles"
      fi
    done
  done
  for s in $SESSIONS; do
    [ -f "$STATE/session-handles/$s.runs" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      in_set "$line" "$CAPTURED" || CAPTURED="${CAPTURED:+$CAPTURED }$line"
    done < "$STATE/session-handles/$s.runs"
  done
}

# RUNH: the coordinator handle of one marker Run, "" when it is null, "!" when it could not be read; run-show is called once per distinct Run.
RUNH=""
RUN_CACHE_IDS=(); RUN_CACHE_V=()
run_handle() {  # run_handle <run id>
  local i=0 out rc=0
  while [ "$i" -lt "${#RUN_CACHE_IDS[@]}" ]; do
    if [ "${RUN_CACHE_IDS[$i]}" = "$1" ]; then RUNH="${RUN_CACHE_V[$i]}"; return 0; fi
    i=$((i + 1))
  done
  out="$(orca orchestration run-show --id "$1" --json --full 2>/dev/null)"; rc=$?
  read_scope
  if [ "$rc" != 0 ] || ! printf '%s' "$out" | jq -e '.result.run | type == "object"' >/dev/null 2>&1; then
    RUNH='!'
  else
    RUNH="$(printf '%s' "$out" | jq -r '.result.run.coordinator_handle | if type == "string" then . elif . == null then "" else "!" end' 2>/dev/null)"
  fi
  RUN_CACHE_IDS+=("$1"); RUN_CACHE_V+=("$RUNH")
}

i=0
while [ "$i" -lt "$N" ]; do
  id="${IDS[$i]}"; path="${DIRS[$i]}"; base="${path##*/}"
  if [ "$SCOPE" = 1 ]; then
    run_handle "${RIDS[$i]}"
    verdict=""
    if [ "$RUNH" = '!' ]; then verdict=unreadable
    elif [ "$RUNH" = "" ]; then
      owner="$(sed -n 2p "${GDS[$i]}/orca-roles.coordinator" 2>/dev/null)"
      if in_set "${RIDS[$i]}" "$CAPTURED"; then verdict=selected
      elif valid_handle "${owner:-}" && in_set "$owner" "$SCOPE_HANDLES"; then verdict=selected
      else verdict=unbound; fi
    elif valid_handle "$RUNH" && in_set "$RUNH" "$SCOPE_HANDLES"; then verdict=selected
    else verdict=other; fi
    case "$verdict" in
      other) say "$path: other-coordinator (${RIDS[$i]})"; i=$((i + 1)); continue;;
      unbound) say "$path: unbound-run (${RIDS[$i]})"
        SUMMARY="$SUMMARY
$base: its Run (${RIDS[$i]}) is bound to no tab and nothing records it as this coordinator's; not reopened. Run launch.sh --reopen in it if it is yours."
        i=$((i + 1)); continue;;
      unreadable) say "$path: run-unreadable (${RIDS[$i]})"
        SUMMARY="$SUMMARY
$base: could not read its Run (${RIDS[$i]}) from Orca; not reopened."
        FAILED=$((FAILED + 1)); i=$((i + 1)); continue;;
    esac
    SELECTED=$((SELECTED + 1))
  fi
  attempt=0; rc=1; out=""
  while [ "$attempt" -lt "$TRIES" ]; do
    attempt=$((attempt + 1))
    timed=0
    bounded_run --quiet --cd "$path" "$LAUNCH_MAX" "launch.sh id:$id --reopen" "$KIT/bin/launch.sh" "id:$id" --reopen > "$TRY_OUT" 2>&1 < /dev/null; rc=$?
    [ "$BOUNDED_TIMED" = 1 ] && timed=1
    out="$(cat "$TRY_OUT" 2>/dev/null)"
    if [ "$timed" = 1 ]; then out="${out:+$out
}launch.sh did not finish within $LAUNCH_MAX s"; fi
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | while IFS= read -r line; do say "$base: $line"; done
    fi
    [ "$rc" = 0 ] && break
    if [ "$attempt" -lt "$TRIES" ]; then
      slog "$base: launch.sh exited $rc (try $attempt of $TRIES); trying again in ${PAUSE} s"
      [ "$PAUSE" = 0 ] || sleep "$PAUSE"
    fi
  done
  if [ "$rc" != 0 ]; then
    last="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1)"
    [ -n "$last" ] || last="exit $rc"
    SUMMARY="$SUMMARY
$path: failed: $(printf '%s' "$last" | cut -c1-200)"
    FAILED=$((FAILED + 1))
  elif case "$out" in *'All roles are already open.'*|*'Nothing to reopen'*) true;; *) false;; esac; then
    SUMMARY="$SUMMARY
$path: nothing to reopen"
    NOTHING=$((NOTHING + 1))
  else
    roles="$(printf '%s\n' "$out" | sed -n 's/^Resuming workspace:\(.*\) start without memory.*$/\1/p' | head -n 1)"
    roles="$(printf '%s' "$roles" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed 's/ /, /g')"
    if [ -n "$roles" ]; then
      SUMMARY="$SUMMARY
$path: reopened (without memory: $roles)"
    else
      SUMMARY="$SUMMARY
$path: reopened"
    fi
    REOPENED=$((REOPENED + 1))
  fi
  i=$((i + 1))
done
if [ "$SCOPE" = 1 ] && [ "$SELECTED" = 0 ]; then
  SUMMARY="$SUMMARY
No coordinated worktree of this coordinator has a team to reopen."
fi
SUMMARY="$SUMMARY
Done: $REOPENED reopened, $NOTHING nothing to reopen, $FAILED failed."

printf '%s\n' "$SUMMARY" > "$SUMMARY_FILE"
printf '%s\n' "$SUMMARY" | while IFS= read -r line; do say "$line"; done

# One status to the coordinator's tab, sent once more as that tab's own when Orca finds no sender identity (kickoff.sh's front_send pattern).
H="${ORCA_TERMINAL_HANDLE:-}"
if [ -n "$H" ]; then
  err_code() { printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null | head -n 1; }
  OUT="$(orca orchestration send --to "$H" --type status --subject "Teams reopened" --body "$SUMMARY" --json 2>&1)"; rc=$?
  code="$(err_code "$OUT")"
  if [ "$code" = no_active_sender_terminal ]; then
    OUT="$(orca orchestration send --from "$H" --to "$H" --type status --subject "Teams reopened" --body "$SUMMARY" --json 2>&1)"; rc=$?
    code="$(err_code "$OUT")"
  fi
  if [ "$rc" != 0 ] || [ -n "$code" ]; then slog "the status \"Teams reopened\" was not sent to $H${code:+ ($code)}"; fi
fi

[ "$FAILED" = 0 ] || exit 1
exit 0
