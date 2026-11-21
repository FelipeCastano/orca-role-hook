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
# Registered in ~/.claude/settings.json (hooks.SessionStart) by install.sh, launch.sh and coordinator.sh (ensure_session_hook in lib.sh;
# settings.sessionHook false turns it off). Nothing happens without ORCA_TERMINAL_HANDLE. Always exits 0; errors go to $KIT/state/session-hook.log.
START="$(date +%s)"; DEADLINE=$((START + 10))
KIT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)" || exit 0   # the kit that holds this script, whatever $KIT says
[ -n "${ORCA_TERMINAL_HANDLE:-}" ] || exit 0
SID="-"; LOG="$KIT/state/session-hook.log"
slog() {
  mkdir -p "${LOG%/*}" 2>/dev/null || return 0
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SID" "$*" >> "$LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 200 ]; then tail -n 200 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG"; fi
  return 0
}
# shellcheck source=/dev/null
. "$KIT/bin/lib.sh" 2>/dev/null || { slog "could not load bin/lib.sh (handle $ORCA_TERMINAL_HANDLE)"; exit 0; }
[ -n "$(type -P orca 2>/dev/null)" ] || { slog "no orca on PATH (handle $ORCA_TERMINAL_HANDLE)"; exit 0; }
command -v jq >/dev/null 2>&1 || { slog "no jq (handle $ORCA_TERMINAL_HANDLE)"; exit 0; }
INPUT="$(cat 2>/dev/null)" || INPUT=""
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)" || SID=""
printf '%s' "$SID" | grep -Eq '^[A-Za-z0-9-]{1,64}$' || { SID="-"; slog "no valid session_id on stdin (handle $ORCA_TERMINAL_HANDLE)"; exit 0; }
# the source (startup, resume, clear, compact, fork) does not change what the hook does: the handle is what counts
DIR="$KIT/state/session-handles"
mkdir -p "$DIR" 2>/dev/null || exit 0
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
# A marked session whose handle changed starts the reopen of the coordinated worktrees' teams now, before any Orca call: the lists answer nothing
# usable at restart time, and `--reopen` is idempotent. `<session_id>.reopen` keeps a later start of the same tab from starting it again.
I3=""
REOPEN="$DIR/$SID.reopen"
if [ -n "$PREV" ] && [ "$PREV" != "$ORCA_TERMINAL_HANDLE" ] && [ "$MARK" = coordinator ]; then
  RH=""; [ -f "$REOPEN" ] && RH="$(head -n 1 "$REOPEN" 2>/dev/null)"
  if [ "$RH" != "$ORCA_TERMINAL_HANDLE" ]; then
    if env KIT="$KIT" "$KIT/bin/reopen-teams.sh" --detach >/dev/null 2>&1; then
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
    2) printf 'orca-roles: could not start reopening the teams of the coordinated worktrees; run ~/.orca-roles/bin/reopen-teams.sh --detach.\n';;
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
RL="$(ho orchestration run-list --json --full)" || {
  if orca_older_than "$ORCA_MIN_VERSION"; then slog "run-list failed (Orca $(orca_version) is older than $ORCA_MIN_VERSION)"
  else slog "run-list failed"; fi
  finish; exit 0; }
# newest first: updated_at changes only when a Run is created, bound or released
RUNS="$(printf '%s' "$RL" | jq -r --arg h "$PREV" '[(.result.runs // .result // []) | if type == "array" then .[] else empty end | select(.coordinator_handle == $h)] | sort_by(.updated_at // "", .created_at // "", .id) | reverse | .[].id' 2>/dev/null)" \
  || { slog "run-list gave no list"; finish; exit 0; }
R="$(printf '%s\n' "$RUNS" | head -n 1)"
[ -n "$R" ] || { slog "handle changed from $PREV to $ORCA_TERMINAL_HANDLE: no Run was bound to $PREV"; record; finish; exit 0; }
LEFT="$(printf '%s\n' "$RUNS" | sed 1d | tr '\n' ' ' | sed -e 's/ $//' -e 's/ /, /g')"
ho orchestration run-use --id "$R" --json >/dev/null || { slog "run-use $R failed"; finish; exit 0; }
slog "took Run $R from $PREV to $ORCA_TERMINAL_HANDLE"
[ -z "$LEFT" ] || slog "took Run $R from $PREV; Run(s) $LEFT were also bound to it and were not taken (Orca keeps one Run per tab: this run-use may have released them)"
N="$(ho orchestration check --run "$R" --peek --json | jq -r '.result.count // (.result.messages | length) // 0' 2>/dev/null)" || N=0
case "$N" in ''|*[!0-9]*) N=0;; esac
if [ "$EXPIRED" = 0 ]; then record; else slog "took Run $R but the time ran out before the record was written"; fi
printf 'orca-roles: this tab reopened with a new terminal handle; re-bound Run %s to it. %s message(s) waiting: read them with orca orchestration check --run %s --json.%s\n' "$R" "$N" "$R" "${LEFT:+ Orca keeps one Run per tab: Run(s) $LEFT were also bound to the old tab and were not taken; run-use of one of them would release $R.}"
finish
exit 0
