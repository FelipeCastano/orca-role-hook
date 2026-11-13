#!/usr/bin/env bash
# Restarts the local coordinator in place: once its current turn ends, its conversation is cleared and its role message is resent, in the
# same tab, mode and Run (the message tells it to rebuild its state from the Run and its ledger). With --workers it first cleans every worker,
# the Planner included (clean.sh --all), so the whole team runs the kit's current prompts (after an update that changed them).
# Usage (from the local coordinator's own tab):  restart-coordinator.sh [--workers]
# Never with a task in flight when --workers is given (the caller ensures that). Claude Code only. Log: <git dir>/orca-roles-restart.log.
# Exit: 0 scheduled; 1 cleaning the workers failed (nothing scheduled); 2 refused or usage; 3 cannot run in the background.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
GITDIR="$(git rev-parse --git-dir 2>/dev/null)" && GITDIR="$(cd "$GITDIR" && pwd)" || GITDIR=""
CFG="$GITDIR/orca-roles.config.json"; STATE="$GITDIR/orca-roles.env"; LOG="$GITDIR/orca-roles-restart.log"

# Detached from this process and from its terminal (double fork + new session), because Orca kills the process group of a tab when it closes it.
detached_start() {  # detached_start <log> <command> [args...]
  local log="$1"; shift
  if command -v setsid >/dev/null 2>&1; then ( setsid "$@" </dev/null >>"$log" 2>&1 & )
  elif [ -x /usr/bin/perl ]; then ( /usr/bin/perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!"; exec @ARGV' "$@" </dev/null >>"$log" 2>&1 & )
  else return 1; fi
}

if [ "${1:-}" = --run ]; then   # hidden: the detached worker  --run <handle> <worktree top folder>
  cd "${3:-/}" 2>/dev/null || exit 0
  to=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))
  logit() { while IFS= read -r l; do echo "$(date '+%F %T') $l" >> "$LOG"; done; }
  if ! front_wait_ready "${2:-}" "$to"; then
    echo "The tab ${2:-} was in use or not idle; nothing was sent." | logit
    exit 0
  fi
  orca terminal send --terminal "${2:-}" --text "/clear" --enter --json >/dev/null 2>&1
  orca terminal wait --terminal "${2:-}" --for tui-idle --timeout-ms "$to" --json >/dev/null 2>&1 || true
  M="$("$KIT/bin/clean.sh" --msg local-coordinator)"
  if orca terminal send --terminal "${2:-}" --text "$M" --enter --json >/dev/null 2>&1; then
    echo "Cleared (/clear) and sent the role message to ${2:-}." | logit
  else
    echo "Cleared (/clear); the role message could not be sent to ${2:-}." | logit
  fi
  exit 0
fi

usage() { echo 'Usage: restart-coordinator.sh [--workers]' >&2; exit 2; }
case "${1:-}" in
  -h|--help) sed -n 2,7p "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0;;
esac
workers=0
case "${1:-}" in
  "") ;;
  --workers) workers=1; shift; [ $# -eq 0 ] || usage;;
  *) usage;;
esac

[ -f "$CFG" ] && [ -f "$STATE" ] || { echo "restart-coordinator.sh: run it from the worktree where the roles were opened." >&2; exit 2; }
[ ! -e "$GITDIR/orca-roles.mode-pending" ] || { echo "restart-coordinator.sh: no mode is chosen yet; nothing to restart." >&2; exit 2; }
handle="$(grep '^LOCAL_COORDINATOR=' "$STATE" | head -1 | cut -d= -f2-)"
[ -n "$handle" ] && [ "${ORCA_TERMINAL_HANDLE:-}" = "$handle" ] || { echo "restart-coordinator.sh: run it from the local coordinator's own tab." >&2; exit 2; }
agent="$(rstr "$CFG" local-coordinator agent)"; agent="${agent:-claude}"
[ "$agent" = claude ] || { echo "restart-coordinator.sh: the local coordinator runs $agent, not Claude Code; nothing changed." >&2; exit 2; }

if [ "$workers" = 1 ]; then
  "$KIT/bin/clean.sh" --all || { echo "restart-coordinator.sh: cleaning the workers failed (see above); your conversation was not cleared." >&2; exit 1; }
fi

WTOP="$(git rev-parse --show-toplevel 2>/dev/null)" || WTOP="$PWD"
detached_start "$LOG" "$0" --run "$handle" "$WTOP" || { echo "restart-coordinator.sh: cannot run in the background on this system; nothing changed." >&2; exit 3; }
echo "Your conversation is cleared and your role message resent once this turn ends (log: $LOG). End your turn now."
