#!/usr/bin/env bash
# Assigns a task to a worker's tab and, in the background, checks that the worker started it.
# Usage:  dispatch.sh --task <task_id> --to <handle> [--run <run_id>]
#         dispatch.sh --check-only --task <task_id> --to <handle>
# The first form runs `orca orchestration dispatch --task <t> --to <h> [--run <id>] --inject --json`, prints Orca's JSON unchanged and exits
# with its status at once; when it succeeded, a checker is started detached. --check-only starts only the checker (for a task delivered
# another way; the message goes to $ORCA_TERMINAL_HANDLE).
# The checker (about 35 s at most, nothing printed in the caller's terminal, notes in <git dir>/orca-roles-dispatch.log): Orca's dispatch
# result cannot tell whether the turn began (the brief may stay typed but unsent in the composer), so it polls `orca worktree ps` for
# a row of the worker's pane whose prompt names the task: every 3 s for 15 s. If it has not started it sends Enter once, only when the
# preview of the tab shows "[Pasted text", and polls 15 s more. Still not started: one "Dispatch not started" status to the dispatcher.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
LOG="$GITDIR/orca-roles-dispatch.log"
TICK="${ORCA_ROLES_DISPATCH_TICK:-3}"; POLLS="${ORCA_ROLES_DISPATCH_POLLS:-5}"   # seconds between polls, polls per wait (the tests shorten them)
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# Same detachment as launch.sh's detached_start: Orca kills the process group of a tab when it closes it.
detached_start() {  # detached_start <log> <command> [args...]
  local out="$1"; shift
  if command -v setsid >/dev/null 2>&1; then ( setsid "$@" </dev/null >>"$out" 2>&1 & )
  elif [ -x /usr/bin/perl ]; then ( /usr/bin/perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!"; exec @ARGV' "$@" </dev/null >>"$out" 2>&1 & )
  else return 1; fi
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

if [ "${1:-}" = --watch ]; then   # hidden: the detached checker  --watch <task> <handle> <pane key> <dispatcher handle>
  task="$2"; h="$3"; pane="$4"; creator="$5"; enter=no
  if [ -z "$pane" ]; then log "$h: $task not checked (no pane key for it)"; exit 0; fi
  wait_started "$pane" "$task" && { log "$h: $task started"; exit 0; }
  if orca terminal show --terminal "$h" --json 2>/dev/null | jq -e '.result.terminal.preview // "" | contains("[Pasted text")' >/dev/null 2>&1; then
    if orca terminal send --terminal "$h" --enter --json >/dev/null 2>&1; then enter=yes; log "$h: $task unsent in its composer; Enter re-sent"; fi
    if [ "$enter" = yes ] && wait_started "$pane" "$task"; then log "$h: Enter re-sent, task started"; exit 0; fi
  fi
  body="$h has not started $task after 30 s (Enter re-sent: $enter). Look at its tab or tell the user."
  if [ -n "$creator" ] && orca orchestration send --to "$creator" --type status --subject "Dispatch not started" --body "$body" --json >/dev/null 2>&1; then
    log "$h: $task not started (Enter re-sent: $enter); told $creator"
  else
    log "$h: $task not started (Enter re-sent: $enter); could not tell the dispatcher"
  fi
  exit 0
fi

TASK=""; TO=""; RUN=""; ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="${2:-}"; shift;;
    --to) TO="${2:-}"; shift;;
    --run) RUN="${2:-}"; shift;;
    --check-only) ONLY=1;;
    *) echo "dispatch.sh: unknown option $1" >&2; exit 2;;
  esac
  shift
done
[ -n "$TASK" ] && [ -n "$TO" ] || { echo "Usage: dispatch.sh --task <task_id> --to <handle> [--run <run_id>] | --check-only --task <task_id> --to <handle>" >&2; exit 2; }

if [ "$ONLY" = 1 ]; then
  pane="$(orca terminal show --terminal "$TO" --json 2>/dev/null | jq -r '.result.terminal | select(.tabId != null and .leafId != null) | "\(.tabId):\(.leafId)"' 2>/dev/null)"
  creator="${ORCA_TERMINAL_HANDLE:-}"
  detached_start "$LOG" "$SELF" --watch "$TASK" "$TO" "$pane" "$creator" || log "$TO: $TASK not checked (no way to detach the checker)"
  exit 0
fi

args=(orchestration dispatch --task "$TASK" --to "$TO")
[ -z "$RUN" ] || args+=(--run "$RUN")
OUT="$(orca "${args[@]}" --inject --json)"; rc=$?
printf '%s\n' "$OUT"
if [ "$rc" = 0 ]; then
  pane="$(printf '%s' "$OUT" | jq -r '(.result.dispatch // .result // {}) | .assignee_pane_key // empty' 2>/dev/null)"
  creator="$(printf '%s' "$OUT" | jq -r '(.result.dispatch // .result // {}) | .creator_handle // empty' 2>/dev/null)"
  detached_start "$LOG" "$SELF" --watch "$TASK" "$TO" "$pane" "${creator:-${ORCA_TERMINAL_HANDLE:-}}" || log "$TO: $TASK not checked (no way to detach the checker)"
fi
exit "$rc"
