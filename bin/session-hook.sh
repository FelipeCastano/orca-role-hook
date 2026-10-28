#!/usr/bin/env bash
# Claude Code SessionStart hook of the kit: re-binds the Orca Runs of a tab that was reopened with a new terminal handle.
# Orca notifies a Run only at the terminal that created or last took it (run-create / run-use). When a coordinator or Planner tab is reopened
# (Orca restart, Orca's own `claude --resume`) its session is the same but its handle is new, so its Runs keep the dead handle and it is never
# told that messages arrived. This hook remembers the handle of each session ($KIT/state/session-handles/<session_id>) and, when it changed and the
# old handle is no longer live, takes the Runs bound to the old handle with `orca orchestration run-use` and prints one line for Claude.
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
# one orca call with what is left of the 10 s (at least 1); 124 when the time is up
ho() {
  local rem=$((DEADLINE - $(date +%s)))
  [ "$rem" -ge 1 ] || { EXPIRED=1; return 124; }
  run_limited "$rem" session-hook command orca "$@" 2>/dev/null
}
record() { printf '%s\n' "$ORCA_TERMINAL_HANDLE" > "$DIR/$SID.tmp.$$" && mv "$DIR/$SID.tmp.$$" "$DIR/$SID"; }
# at most once a day: records older than 30 days go
if [ -z "$(find "$DIR" -maxdepth 1 -name .swept -mtime -1 2>/dev/null)" ]; then
  : > "$DIR/.swept"
  find "$DIR" -maxdepth 1 -type f ! -name '.*' -mtime +30 -delete 2>/dev/null
fi
EXPIRED=0
PREV=""; [ -f "$DIR/$SID" ] && PREV="$(head -n 1 "$DIR/$SID" 2>/dev/null)"
if [ -z "$PREV" ] || [ "$PREV" = "$ORCA_TERMINAL_HANDLE" ]; then record; exit 0; fi
# the handle changed: only a dead old handle gives up its Runs; a tab that still lives keeps its own
TL="$(ho terminal list --json)" || { slog "terminal list failed: the Runs of $PREV were not looked at"; exit 0; }
if ! printf '%s' "$TL" | jq -e '.result.terminals | type == "array"' >/dev/null 2>&1; then slog "terminal list gave no list"; exit 0; fi
# a list that is cut short, or leaves a paired host out, cannot show that the old handle is dead
if printf '%s' "$TL" | jq -e '.result.truncated == true or ((.result.hostScope.omittedHostIds // []) | length) > 0' >/dev/null 2>&1; then slog "terminal list incomplete"; exit 0; fi
if printf '%s' "$TL" | jq -e --arg h "$PREV" 'any(.result.terminals[]?; .handle == $h)' >/dev/null 2>&1; then record; exit 0; fi
RL="$(ho orchestration run-list --json)" || { slog "run-list failed"; exit 0; }
RUNS="$(printf '%s' "$RL" | jq -r --arg h "$PREV" '(.result.runs // .result // []) | if type == "array" then .[] else empty end | select(.coordinator_handle == $h) | .id' 2>/dev/null)" \
  || { slog "run-list gave no list"; exit 0; }
BOUND=""; N=0; FAILED=0
for R in $RUNS; do
  if ho orchestration run-use --id "$R" --json >/dev/null; then
    BOUND="${BOUND:+$BOUND, }$R"
    W="$(ho orchestration check --run "$R" --peek --json | jq -r '.result.count // (.result.messages | length) // 0' 2>/dev/null)" || W=0
    case "$W" in ''|*[!0-9]*) W=0;; esac
    N=$((N + W))
  else
    FAILED=1; slog "run-use $R failed"
  fi
done
[ "$FAILED" = 0 ] && [ "$EXPIRED" = 0 ] && record
[ -n "$BOUND" ] && printf 'orca-roles: this tab reopened with a new terminal handle; re-bound Run(s) %s to it. %s message(s) waiting: read them with orca orchestration check --run <id> --json (one per Run).\n' "$BOUND" "$N"
exit 0
