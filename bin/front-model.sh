#!/usr/bin/env bash
# Lets the local coordinator switch its own Claude Code model (and back) between turns, with /model typed in its tab once its turn ends, without
# changing the user's default model (Claude Code's /model may save it; the saved default is put back). Used to rewrite a rejected research brief.
# Usage (from the local coordinator's own tab):  front-model.sh --escalate|--back|<model> [--then "<text>"]
# --escalate: the Planner's model (claude-opus-5-5 when it has none); --back: the local coordinator's configured model; --then: a line typed after the switch.
# Exit: 0 scheduled (the switch happens after the current turn ends); 2 refused (the message says why); 3 cannot run in the background.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
GITDIR="$(git rev-parse --git-dir 2>/dev/null)" && GITDIR="$(cd "$GITDIR" && pwd)" || GITDIR=""
CFG="$GITDIR/orca-roles.config.json"; STATE="$GITDIR/orca-roles.env"; LOG="$GITDIR/orca-roles-front-model.log"

# Detached from this process and from its terminal (double fork + new session), because Orca kills the process group of a tab when it closes it.
detached_start() {  # detached_start <log> <command> [args...]
  local log="$1"; shift
  if command -v setsid >/dev/null 2>&1; then ( setsid "$@" </dev/null >>"$log" 2>&1 & )
  elif [ -x /usr/bin/perl ]; then ( /usr/bin/perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!"; exec @ARGV' "$@" </dev/null >>"$log" 2>&1 & )
  else return 1; fi
}

if [ "${1:-}" = --run ]; then   # hidden: the detached worker  --run <handle> <model> <then>
  to=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))
  logit() { while IFS= read -r l; do echo "$(date '+%F %T') $l" >> "$LOG"; done; }
  set_rc=0
  out="$(front_set_model "${2:-}" "${3:-}" "$to" 2>&1)" || set_rc=$?
  [ -z "$out" ] || printf "%s\n" "$out" | logit
  if [ "$set_rc" = 0 ] && [ -n "${4:-}" ]; then
    if front_wait_ready "$2" "$to"; then
      orca terminal send --terminal "$2" --text "$4" --enter --json >/dev/null 2>&1
      echo "Sent: $4" | logit
    else
      echo "The tab $2 was in use or not idle; this line was not sent: $4" | logit
    fi
  fi
  exit 0
fi

usage() { echo 'Usage: front-model.sh --escalate|--back|<model> [--then "<text>"]' >&2; exit 2; }
mode=""; after=""; have_then=0
while [ $# -gt 0 ]; do
  case "$1" in
    --escalate|--back) [ -z "$mode" ] || usage; mode="$1"; shift;;
    --then) [ "$have_then" = 0 ] && [ $# -ge 2 ] || usage; after="$2"; have_then=1; shift 2;;
    --then=*) [ "$have_then" = 0 ] || usage; after="${1#--then=}"; have_then=1; shift;;
    -*) usage;;
    *) [ -z "$mode" ] || usage; mode="$1"; shift;;
  esac
done
[ -n "$mode" ] || usage

[ -f "$CFG" ] && [ -f "$STATE" ] || { echo "front-model.sh: run it from the worktree where the roles were opened." >&2; exit 2; }
handle="$(grep '^LOCAL_COORDINATOR=' "$STATE" | head -1 | cut -d= -f2-)"
[ -n "$handle" ] && [ "${ORCA_TERMINAL_HANDLE:-}" = "$handle" ] || { echo "front-model.sh: run it from the local coordinator's own tab." >&2; exit 2; }
agent="$(rstr "$CFG" local-coordinator agent)"; agent="${agent:-claude}"
[ "$agent" = claude ] || { echo "front-model.sh: the local coordinator runs $agent, not Claude Code; its model cannot be switched from here. Nothing changed." >&2; exit 2; }

case "$mode" in
  --escalate) target="$(rstr "$CFG" planner model)"; target="${target:-claude-opus-5-5}";;
  --back) target="$(rstr "$CFG" local-coordinator model)"
    [ -n "$target" ] || { echo "front-model.sh: the local coordinator has no model of its own in the configuration (it runs the agent's default); nothing to switch back to." >&2; exit 2; };;
  *) target="$mode";;
esac

detached_start "$LOG" "$0" --run "$handle" "$target" "$after" || { echo "front-model.sh: cannot run in the background on this system; nothing changed." >&2; exit 3; }
echo "Your model switches to $target once this turn ends (log: $LOG). End your turn now."
