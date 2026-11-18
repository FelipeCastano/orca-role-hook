#!/usr/bin/env bash
# Claude Code SessionStart hook of the kit: re-binds the Orca Runs of a tab that was reopened with a new terminal handle, and starts the
# reopen of the coordinated worktrees' teams when that tab is a global coordinator's.
# Orca notifies a Run only at the terminal that created or last took it (run-create / run-use). When the front role's tab (the local coordinator) is reopened
# (Orca restart, Orca's own `claude --resume`) its session is the same but its handle is new, so its Runs keep the dead handle and it is never
# told that messages arrived. This hook remembers the handle of each session ($KIT/state/session-handles/<session_id>) and, when it changed and the
# old handle is no longer live (it looks again twice, 2 s apart, when the old tab is still listed), takes the Run bound to the old handle with `orca orchestration run-use` and prints one line for Claude.
# Orca keeps one Run per tab (run-use releases every other Run bound to the tab), so when several are bound to the old handle it takes only the one
# created or bound last (updated_at) and names the others in its line and its log: after a restart that run-use releases them (the restored tab keeps
# the old tab's pane), and they stay on the old handle only when the new tab is another pane.
# A session that coordinator.sh marked (ORCA_ROLES_SESSION_KIND=coordinator; the record keeps `coordinator` on line 2 once seen) and that starts
# with a new handle also starts `bin/reopen-teams.sh --detach` in the background, before any Orca call and whatever its lists answer, and prints a
# last line saying so. `<session_id>.reopen` holds the handle that start was for, so a later start of the same tab (compact, clear) does not repeat it.
# A marked session keeps the handles it has had in `<session_id>.handles` (one per line, in the order first seen) and the Runs its own `run-use`
# may release in `<session_id>.runs`: both are written before the hook can stop early, so the reopen finds the coordinator's Runs even when a
# later `run-use` of another tab released them; the hook touches them at every start, so the 30-day sweep keeps them while the tab is live.
# The reopen gets both handles (`--coordinator <old> --coordinator <new>`); the hook's run-list is read page by page (--limit 100, --cursor).
# Registered in ~/.claude/settings.json (hooks.SessionStart) by install.sh, launch.sh and coordinator.sh (ensure_session_hook in lib.sh;
# settings.sessionHook false turns it off). Nothing happens without ORCA_TERMINAL_HANDLE. Always exits 0; errors go to $KIT/state/session-hook.log.
START="$(date +%s)"; DEADLINE=$((START + 10))
KIT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)" || exit 0   # the kit that holds this script, whatever $KIT says
[ -n "${ORCA_TERMINAL_HANDLE:-}" ] || exit 0
# shellcheck source=/dev/null
. "$KIT/bin/lib.sh" 2>/dev/null || exit 0
[ -n "$(type -P orca 2>/dev/null)" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null)" || INPUT=""
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)" || SID=""
printf '%s' "$SID" | grep -Eq '^[A-Za-z0-9-]{1,64}$' || exit 0
# the source (startup, resume, clear, compact, fork) does not change what the hook does: the handle is what counts
DIR="$KIT/state/session-handles"; LOG="$KIT/state/session-hook.log"
mkdir -p "$DIR" 2>/dev/null || exit 0
slog() {
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SID" "$*" >> "$LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 200 ]; then tail -n 200 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG"; fi
  return 0
}
# one orca call with what is left of the 10 s (at least 1); 124 when the time is up. The version lookup inside orca_compat_args gets what is left too.
ho() {
  local rem
  rem=$((DEADLINE - $(date +%s)))
  [ "$rem" -ge 1 ] || { EXPIRED=1; return 124; }
  # shellcheck disable=SC2034  # read by orca_version in bin/lib.sh
  local ORCA_ROLES_VERSION_TIMEOUT="$rem"
  orca_compat_args "$@"
  rem=$((DEADLINE - $(date +%s)))
  [ "$rem" -ge 1 ] || { EXPIRED=1; return 124; }
  bounded_run "$rem" session-hook command orca ${ORCA_COMPAT_ARGS[@]+"${ORCA_COMPAT_ARGS[@]}"} 2>/dev/null
}
record() {
  if [ "$MARK" = coordinator ]; then
    { printf '%s\n' "$ORCA_TERMINAL_HANDLE"; printf 'coordinator\n'; } > "$DIR/$SID.tmp.$$" && mv "$DIR/$SID.tmp.$$" "$DIR/$SID"
  else
    printf '%s\n' "$ORCA_TERMINAL_HANDLE" > "$DIR/$SID.tmp.$$" && mv "$DIR/$SID.tmp.$$" "$DIR/$SID"
  fi
}
valid_handle() { [ -n "${1:-}" ] || return 1; case "$1" in *[!A-Za-z0-9_-]*) return 1;; esac; return 0; }
# at most once a day: records older than 30 days go; the .reopen records age out with them
if [ -z "$(find "$DIR" -maxdepth 1 -name .swept -mtime -1 2>/dev/null)" ]; then
  : > "$DIR/.swept"
  find "$DIR" -maxdepth 1 -type f ! -name '.*' -mtime +30 -delete 2>/dev/null
fi
# The mark that makes a session a global coordinator's: this environment, or the line 2 an earlier start kept in its record.
MARK=""
[ "${ORCA_ROLES_SESSION_KIND:-}" = coordinator ] && MARK=coordinator
if [ -z "$MARK" ] && [ -f "$DIR/$SID" ] && [ "$(sed -n 2p "$DIR/$SID" 2>/dev/null)" = coordinator ]; then MARK=coordinator; fi
EXPIRED=0
PREV=""; [ -f "$DIR/$SID" ] && PREV="$(head -n 1 "$DIR/$SID" 2>/dev/null)"
# A marked session keeps every handle it has had in `<session_id>.handles`, and touches that file and its `.runs` file at every start so the
# 30-day sweep never removes the history of a session whose record is still fresh. Written here, before the reopen decision and before any Orca
# call: a hook that stops early (a failed list, the deadline) still leaves both handles known. Unmarked sessions get no history.
HIST="$DIR/$SID.handles"
record_handles() {
  local tmp="$DIR/$SID.handles.tmp.$$" h ok=1
  : > "$tmp" 2>/dev/null || ok=0
  if [ "$ok" = 1 ] && [ -f "$HIST" ]; then cat "$HIST" >> "$tmp" 2>/dev/null || ok=0; fi
  if [ "$ok" = 1 ]; then
    for h in "$PREV" "$ORCA_TERMINAL_HANDLE"; do
      valid_handle "$h" || continue
      grep -Fxq -e "$h" "$tmp" 2>/dev/null && continue
      printf '%s\n' "$h" >> "$tmp" 2>/dev/null || { ok=0; break; }
    done
  fi
  if [ "$ok" = 1 ] && mv "$tmp" "$HIST" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null
  slog "could not record the handles of this session"
  return 1
}
if [ "$MARK" = coordinator ]; then
  record_handles
  [ ! -f "$HIST" ] || touch "$HIST" 2>/dev/null || true
  [ ! -f "$DIR/$SID.runs" ] || touch "$DIR/$SID.runs" 2>/dev/null || true
fi
# A marked session whose handle changed starts the reopen of the coordinated worktrees' teams now, before any Orca call: the lists answer nothing
# usable at restart time, and `--reopen` is idempotent. `<session_id>.reopen` keeps a later start of the same tab from starting it again.
I3=""
REOPEN="$DIR/$SID.reopen"
if [ -n "$PREV" ] && [ "$PREV" != "$ORCA_TERMINAL_HANDLE" ] && [ "$MARK" = coordinator ]; then
  RH=""; [ -f "$REOPEN" ] && RH="$(head -n 1 "$REOPEN" 2>/dev/null)"
  if [ "$RH" != "$ORCA_TERMINAL_HANDLE" ]; then
    if ! valid_handle "$PREV" || ! valid_handle "$ORCA_TERMINAL_HANDLE"; then
      I3=2
      slog "could not start reopen-teams.sh --detach (invalid handle)"
    elif env KIT="$KIT" "$KIT/bin/reopen-teams.sh" --detach --coordinator "$PREV" --coordinator "$ORCA_TERMINAL_HANDLE" >/dev/null 2>&1; then
      I3=1
      printf '%s\n' "$ORCA_TERMINAL_HANDLE" > "$REOPEN" 2>/dev/null || true
    else
      I3=2
      slog "could not start reopen-teams.sh --detach"
    fi
  fi
fi
# The last line of every end after that decision says whether the reopen was started (or that it could not be).
finish() {
  case "$I3" in
    1) printf 'orca-roles: reopening the teams of the coordinated worktrees in the background (log: %s/state/reopen-teams.log); the result comes as a status "Teams reopened" and in %s/state/reopen-teams.last.\n' "$KIT" "$KIT";;
    2) if valid_handle "$PREV" && valid_handle "$ORCA_TERMINAL_HANDLE"; then
         printf 'orca-roles: could not start reopening the teams of the coordinated worktrees; run ~/.orca-roles/bin/reopen-teams.sh --detach --coordinator %s --coordinator %s.\n' "$PREV" "$ORCA_TERMINAL_HANDLE"
       else
         printf 'orca-roles: could not start reopening the teams of the coordinated worktrees; run ~/.orca-roles/bin/reopen-teams.sh --detach.\n'
       fi;;
  esac
  return 0
}
if [ -z "$PREV" ] || [ "$PREV" = "$ORCA_TERMINAL_HANDLE" ]; then record; exit 0; fi
# TL = one complete terminal list; otherwise log why and return 1. A list that is cut short, or leaves a paired host out, cannot show that the old handle is dead
tl() {
  TL="$(ho terminal list --json)" || { slog "terminal list failed: the Runs of $PREV were not looked at"; return 1; }
  printf '%s' "$TL" | jq -e '.result.terminals | type == "array"' >/dev/null 2>&1 || { slog "terminal list gave no list"; return 1; }
  if printf '%s' "$TL" | jq -e '.result.truncated == true or ((.result.hostScope.omittedHostIds // []) | length) > 0' >/dev/null 2>&1; then slog "terminal list incomplete"; return 1; fi
}
listed() { printf '%s' "$TL" | jq -e --arg h "$PREV" 'any(.result.terminals[]?; .handle == $h)' >/dev/null 2>&1; }
tl || { finish; exit 0; }
# the old tab can stay listed for a moment after it was closed (launch.sh closes the tab Orca restored, then opens this one with the same session):
# look again at most twice, 2 s apart, only while 6 s of the 10 are left (more than 3 s stay for the re-look's own list, run-list, run-use and check)
LOOKS=0
while listed && [ "$LOOKS" -lt 2 ] && [ $((DEADLINE - $(date +%s))) -ge 6 ]; do
  sleep 2; LOOKS=$((LOOKS + 1)); tl || { finish; exit 0; }
done
# only a dead old handle gives up its Runs; a tab that still lives keeps its own
if listed; then slog "the old tab $PREV is still listed (looked $((LOOKS + 1)) times): its Runs stay with it"; record; finish; exit 0; fi
RL=""; PAGES=0; CURSOR=""; ACC=""; SHORT=0; NEXT=""
# Paged read (D8): the Runs beyond the first 100 must not be missed, and the page read must stay inside the hook's deadline. At most 20 pages,
# each next one only while at least 3 s are left; a failed or cut read of a later page keeps the pages read and says so in the log.
while :; do
  if [ -z "$CURSOR" ]; then
    RL="$(ho orchestration run-list --limit 100 --json --full)" || {
      if orca_older_than "$ORCA_MIN_VERSION"; then slog "run-list failed (Orca $(orca_version) is older than $ORCA_MIN_VERSION)"
      else slog "run-list failed"; fi
      finish; exit 0; }
  else
    [ $((DEADLINE - $(date +%s))) -ge 3 ] || { SHORT=1; break; }
    RL="$(ho orchestration run-list --limit 100 --cursor "$CURSOR" --json --full)" || { SHORT=1; break; }
  fi
  if ! printf '%s' "$RL" | jq -e 'type == "object"' >/dev/null 2>&1; then
    if [ "$PAGES" = 0 ]; then slog "run-list gave no list"; finish; exit 0; fi
    SHORT=1; break
  fi
  PAGES=$((PAGES + 1))
  ACC="${ACC}$(printf '%s' "$RL" | jq -c '(.result.runs // .result // []) | if type == "array" then .[] else empty end' 2>/dev/null)"
  NEXT="$(printf '%s' "$RL" | jq -r 'if (.result.nextCursor | type) == "string" then .result.nextCursor else "" end' 2>/dev/null)"
  [ -n "$NEXT" ] || break
  [ "$PAGES" -lt 20 ] || { SHORT=1; break; }
  CURSOR="$NEXT"
done
[ "$SHORT" = 0 ] || slog "run-list incomplete: read $PAGES page(s)"
# newest first: updated_at changes only when a Run is created, bound or released
RUNS="$(printf '%s' "$ACC" | jq -r --arg h "$PREV" -s '[.[] | select(.coordinator_handle == $h)] | sort_by(.updated_at // "", .created_at // "", .id) | reverse | .[].id' 2>/dev/null)" \
  || { slog "run-list gave no list"; finish; exit 0; }
# The Runs this hook's own run-use may release stay attributable to the coordinator: recorded before run-use, never removed here.
if [ -n "$RUNS" ]; then
  CAPTURE="$DIR/$SID.runs"; CTMP="$DIR/$SID.runs.tmp.$$"; ok=1; r=""
  : > "$CTMP" 2>/dev/null || ok=0
  if [ "$ok" = 1 ] && [ -f "$CAPTURE" ]; then cat "$CAPTURE" >> "$CTMP" 2>/dev/null || ok=0; fi
  if [ "$ok" = 1 ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      grep -Fxq -e "$r" "$CTMP" 2>/dev/null && continue
      printf '%s\n' "$r" >> "$CTMP" 2>/dev/null || { ok=0; break; }
    done <<EOF
$RUNS
EOF
  fi
  if [ "$ok" = 1 ] && mv "$CTMP" "$CAPTURE" 2>/dev/null; then :
  else slog "could not record the Runs of $PREV"; rm -f "$CTMP" 2>/dev/null; fi
fi
R="$(printf '%s\n' "$RUNS" | head -n 1)"
[ -n "$R" ] || { record; finish; exit 0; }
LEFT="$(printf '%s\n' "$RUNS" | sed 1d | tr '\n' ' ' | sed -e 's/ $//' -e 's/ /, /g')"
ho orchestration run-use --id "$R" --json >/dev/null || { slog "run-use $R failed"; finish; exit 0; }
[ -z "$LEFT" ] || slog "took Run $R from $PREV; Run(s) $LEFT were also bound to it and were not taken (Orca keeps one Run per tab: this run-use may have released them)"
N="$(ho orchestration check --run "$R" --peek --json | jq -r '.result.count // (.result.messages | length) // 0' 2>/dev/null)" || N=0
case "$N" in ''|*[!0-9]*) N=0;; esac
[ "$EXPIRED" = 0 ] && record
printf 'orca-roles: this tab reopened with a new terminal handle; re-bound Run %s to it. %s message(s) waiting: read them with orca orchestration check --run %s --json.%s\n' "$R" "$N" "$R" "${LEFT:+ Orca keeps one Run per tab: Run(s) $LEFT were also bound to the old tab and were not taken; run-use of one of them would release $R.}"
finish
exit 0
