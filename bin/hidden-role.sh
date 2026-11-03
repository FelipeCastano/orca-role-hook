#!/usr/bin/env bash
# Runs a role that has "open": "hidden" (no tab) headless, for one task, and sends the local coordinator one message with its report.
# Usage (from the worktree, in the local coordinator's tab):
#   hidden-role.sh <role|title> --brief <file> --tag <tag> [--resume <session id>]   start a run (returns at once; the result arrives as a status message)
#   hidden-role.sh --stop <role>      end the role's run in flight (its message arrives with outcome=failed, text "stopped")
#   hidden-role.sh --status           running runs, results that never reached the coordinator (undelivered) and runs that ended with no report (lost)
#   hidden-role.sh --ack <tag>        stop listing a handled undelivered or lost result
# The message: status "Hidden role done" (or "Hidden role question"), body "role=<id> tag=<tag> outcome=<done|failed|question> marker=<ok|missing>
# session=<id or -> wall=<seconds> report=<file>", then the start of the report. Claude only: see HIDDEN_AGENTS in lib.sh.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
GITDIR="$(git rev-parse --git-dir 2>/dev/null)" && GITDIR="$(cd "$GITDIR" && pwd)" || GITDIR=""
CFG="${GITDIR:+$GITDIR/orca-roles.config.json}"
H="${GITDIR:+$GITDIR/orca-roles-hidden}"
valid_tag() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1;; esac; }

# One adapter per agent: reads what the agent printed (<out>), writes its final text to <text>, prints its session id (nothing if it has none).
# Exit 0: a result the agent calls a success. Exit 1: no usable output, or an error by its own account. Adding an agent: a word in
# HIDDEN_AGENTS, a headless branch in agent.sh, an adapter here.
adapter_claude() {  # adapter_claude <out> <text>
  jq -r 'objects | .session_id // empty' "$1" 2>/dev/null   # first: an error result with no .result still has a session to resume
  jq -e 'type == "object" and (.result | type == "string")' "$1" >/dev/null 2>&1 || return 1
  jq -r .result "$1" > "$2"
  jq -e '.is_error != true' "$1" >/dev/null
}
adapter() { case "$AGENT" in claude) adapter_claude "$@";; *) return 1;; esac; }   # adapter <out> <text>

# Same detachment as dispatch.sh's detached_start: Orca kills the process group of a tab when it closes it.
detached_start() {  # detached_start <log> <command> [args...]
  local out="$1"; shift
  if command -v setsid >/dev/null 2>&1; then ( setsid "$@" </dev/null >>"$out" 2>&1 & )
  elif [ -x /usr/bin/perl ]; then ( /usr/bin/perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!"; exec @ARGV' "$@" </dev/null >>"$out" 2>&1 & )
  else return 1; fi
}

pidfield() { local a b c d e; read -r a b c d e < "$1" 2>/dev/null; case "$2" in 1) echo "${a:-}";; 2) echo "${b:--}";; 3) echo "${c:-}";; 4) echo "${d:--}";; 5) echo "${e:-}";; esac; }   # pidfield <file> <n>

# Every pid file that hidden_live calls dead moves to <tag>.lost, with its role inside: what no trap can cover (a restart, a kill -9).
reap() {
  local f role tag
  for f in "$H"/*.pid; do
    [ -f "$f" ] || continue
    role="$(basename "$f" .pid)"
    hidden_live "$GITDIR" "$role" && continue
    tag="$(pidfield "$f" 5)"
    valid_tag "$tag" || tag="unknown-$role"
    mv "$f" "$H/$tag.lost" 2>/dev/null && printf 'role=%s\n' "$role" >> "$H/$tag.lost"
  done
}

need_team() { [ -n "$GITDIR" ] && [ -f "$CFG" ] || { echo "hidden-role.sh: no team in this folder: run it from the worktree where the roles were opened." >&2; exit 2; }; }

# ---- the supervisor: one per run, detached ----
if [ "${1:-}" = --supervise ]; then
  role="$2"; brief="$3"; tag="$4"; rid="$5"
  need_team
  AGENT="$(rstr "$CFG" "$role" agent)"; AGENT="${AGENT:-claude}"
  LOG="$H/$tag.log"; R="$(scratch_dir "$role")/hidden-$tag.md"; PF="$H/$role.pid"
  SENT=0; AGPID=""; SES=""
  mkdir -p "$(dirname "$R")" 2>/dev/null

  # deliver <subject> <body>: undelivered file first, then the pid file goes, then the send (3 tries). One message per run, whatever interrupts it.
  deliver() {
    local i
    printf '%s\n' "$2" > "$H/$tag.undelivered"
    rm -f "$PF"
    SENT=1
    for i in 1 2 3; do
      if orca orchestration send --to "${ORCA_TERMINAL_HANDLE:-}" --type status --subject "$1" --body "$2" --json >/dev/null 2>>"$LOG"; then
        rm -f "$H/$tag.undelivered"; return 0
      fi
      [ "$i" = 3 ] || pace 2
    done
    echo "hidden-role.sh: could not deliver the message of $tag (3 tries); left in $H/$tag.undelivered" >> "$LOG"
    return 1
  }
  # finish <outcome> <text>: the report file, the marker and the message
  finish() {
    local outcome="$1" text="$2" marker=missing subject="Hidden role done" session sec
    printf '%s\n' "$text" > "$R"
    printf '%s' "$text" | jq -e -R -s --arg re "$REPORT_MARK_RE" 'test($re; "i")' >/dev/null 2>&1 && marker=ok
    [ "$outcome" = question ] && subject="Hidden role question"
    session="${SES:-}"; [ -n "$session" ] || session="$rid"; { [ -n "$session" ] && [ "$session" != - ]; } || session=-
    sec="$SECONDS"
    deliver "$subject" "$(printf 'role=%s tag=%s outcome=%s marker=%s session=%s wall=%s report=%s\n%s' "$role" "$tag" "$outcome" "$marker" "$session" "$sec" "$R" "$(printf '%s' "$text" | jq -Rrs '.[0:1500]')")"
  }
  on_exit() {
    [ "$SENT" = 1 ] && return 0
    [ -z "$AGPID" ] || kill -TERM -- "-$AGPID" 2>/dev/null
    finish failed "the supervisor ended before the run did
$(tail -n 20 "$LOG" 2>/dev/null)"
  }
  trap on_exit EXIT
  trap 'exit 143' TERM HUP INT

  PROMPT="$H/$tag.prompt"
  if ! BT="$(cat "$brief" 2>/dev/null)" || [ ! -r "$brief" ]; then
    finish failed "the brief $brief could not be read
$(tail -n 20 "$LOG" 2>/dev/null)"
    exit 0
  fi
  CLOSING='When you have finished, your last message is your report, and its first word is `Done`.'
  {
    if [ "$rid" = - ]; then
      printf '%s\n\n' "$(worker_msg "$CFG" "$role")"
      printf '%s\n\n' 'Read those files before anything else, even for a small task.'
      cat "$KIT/prompts/hidden-worker.md"; printf '\n'
      printf '%s\n\n' 'Your task:'
    fi
    printf '%s\n\n' "$BT"
    printf '%s\n' "$CLOSING"
  } > "$PROMPT"

  AGARGS=("$role"); [ "$rid" = - ] || AGARGS+=(--resume "$rid")
  OUT="$H/$tag.json"; : > "$OUT"
  (
    for v in $(compgen -e); do case "$v" in ORCA_ROLES_*) ;; ORCA_*) unset "$v";; esac; done
    if [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]; then
      OTEL_RESOURCE_ATTRIBUTES="$(printf '%s' "$OTEL_RESOURCE_ATTRIBUTES" | tr ',' '\n' | grep -v '^orca_roles\.role=' | paste -sd, -)"
      if [ -n "$OTEL_RESOURCE_ATTRIBUTES" ]; then export OTEL_RESOURCE_ATTRIBUTES; else unset OTEL_RESOURCE_ATTRIBUTES; fi
    fi
    export ORCA_ROLES_CONFIG="$CFG" ORCA_ROLES_HEADLESS_PROMPT="$PROMPT"
    if command -v setsid >/dev/null 2>&1; then exec setsid "$KIT/bin/agent.sh" "${AGARGS[@]}"
    else exec /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$KIT/bin/agent.sh" "${AGARGS[@]}"; fi
  ) > "$OUT" 2>> "$LOG" < /dev/null &
  AGPID=$!
  as="$(proc_start "$AGPID")"; ss="$(proc_start $$)"
  printf '%s %s %s %s %s\n' "$AGPID" "${as:--}" "$$" "${ss:--}" "$tag" > "$PF.tmp.$$" && mv "$PF.tmp.$$" "$PF"
  wait "$AGPID"; rc=$?

  : > "$R"
  SES="$(adapter "$OUT" "$R")"; arc=$?
  if [ -e "$H/$role.stop" ]; then
    rm -f "$H/$role.stop"; outcome=failed; text=stopped
  else
    text="$(cat "$R" 2>/dev/null)"
    if [ "$rc" != 0 ] || [ "$arc" != 0 ]; then
      outcome=failed
      [ -n "$text" ] || text="the run ended without a usable result (exit $rc)
$(tail -n 20 "$LOG" 2>/dev/null)"
    else
      last="$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n 1)"
      case "$last" in
        'QUESTION: '*) outcome=question;;
        'FAILED: '*) outcome=failed;;
        *) outcome='done';;
      esac
    fi
  fi
  finish "$outcome" "$text"
  exit 0
fi

# ---- --status, --ack, --stop ----
if [ "${1:-}" = --status ]; then
  need_team; mkdir -p "$H"; reap
  for f in "$H"/*.pid; do [ -f "$f" ] && echo "running $(basename "$f" .pid) $(pidfield "$f" 5)"; done
  for f in "$H"/*.undelivered; do
    [ -f "$f" ] || continue
    echo "undelivered $(basename "$f" .undelivered) $(head -n 1 "$f" | sed -n 's/.* report=//p')"
  done
  for f in "$H"/*.lost; do
    [ -f "$f" ] || continue
    t="$(basename "$f" .lost)"; r="$(grep -m1 '^role=' "$f" | cut -d= -f2-)"
    lg="$H/$t.log"; case "$t" in unknown-*) lg=-;; esac
    echo "lost $r $t $lg"
  done
  exit 0
fi
if [ "${1:-}" = --ack ]; then
  need_team; t="${2:-}"
  if valid_tag "$t" && { [ -e "$H/$t.undelivered" ] || [ -e "$H/$t.lost" ]; }; then
    rm -f "$H/$t.undelivered" "$H/$t.lost"; exit 0
  fi
  echo "nothing to acknowledge for $t" >&2; exit 1
fi
if [ "${1:-}" = --stop ]; then
  need_team; role="${2:-}"
  [ -n "$role" ] || { echo "Usage: hidden-role.sh --stop <role>" >&2; exit 2; }
  r="$(resolve_role "$CFG" "$role")"; [ -z "$r" ] || role="$r"
  valid_tag "$role" || { echo "hidden-role.sh: unknown role $role" >&2; exit 2; }
  PF="$H/$role.pid"
  if [ ! -f "$PF" ] || ! hidden_live "$GITDIR" "$role"; then echo "$role is not running"; exit 1; fi
  if [ "$(pidfield "$PF" 1)" = starting ]; then
    for _ in $(seq 1 25); do
      case "$(pidfield "$PF" 1)" in ''|starting) sleep 0.2;; *) break;; esac
    done
    case "$(pidfield "$PF" 1)" in starting) echo "$role has not started yet"; exit 1;; esac
  fi
  ap="$(pidfield "$PF" 1)"; as="$(pidfield "$PF" 2)"; sp="$(pidfield "$PF" 3)"; ss="$(pidfield "$PF" 4)"
  if proc_is "$ap" "$as"; then
    touch "$H/$role.stop"
    kill -TERM -- "-$ap" 2>/dev/null
    for _ in $(seq 1 25); do kill -0 -- "-$ap" 2>/dev/null || break; sleep 0.2; done
    # a pid reused as a new group leader inside this 5 s poll is accepted
    if kill -0 -- "-$ap" 2>/dev/null; then kill -KILL -- "-$ap" 2>/dev/null; fi
    echo "Stopped $role"; exit 0
  fi
  if proc_is "$sp" "$ss"; then echo "$role has ended; its result is on its way"; exit 1; fi
  echo "$role has ended"; exit 1
fi

# ---- start a run ----
ROLEARG=""; BRIEF=""; TAG=""; RESUME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) BRIEF="${2:-}"; shift;;
    --tag) TAG="${2:-}"; shift;;
    --resume) RESUME="${2:-}"; shift;;
    -*) echo "hidden-role.sh: unknown option $1" >&2; exit 2;;
    *) [ -z "$ROLEARG" ] && ROLEARG="$1" || { echo "hidden-role.sh: only one role at a time" >&2; exit 2; };;
  esac
  shift
done
[ -n "$ROLEARG" ] && [ -n "$BRIEF" ] || { sed -n 2,6p "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
need_team
ROLE="$(resolve_role "$CFG" "$ROLEARG")"
[ -n "$ROLE" ] || { echo "hidden-role.sh: unknown role $ROLEARG" >&2; exit 2; }
TITLE="$(title_of "$CFG" "$ROLE")"
[ "$(open_of "$CFG" "$ROLE")" = hidden ] || { echo "$ROLE does not open hidden" >&2; exit 2; }
AGENT="$(rstr "$CFG" "$ROLE" agent)"; AGENT="${AGENT:-claude}"
hidden_capable "$AGENT" || { echo "$ROLE does not open hidden: its agent $AGENT cannot run hidden" >&2; exit 2; }
LR="$(launchable_roles "$CFG" 2>/dev/null)"; printf '%s\n' "$LR" | grep -qx "$ROLE" || { echo "$ROLE is not in this team" >&2; exit 2; }
if grep -q "^$(var_of "$ROLE")=." "$GITDIR/orca-roles.env" 2>/dev/null; then echo "$ROLE has a tab: dispatch to it" >&2; exit 2; fi
[ -r "$BRIEF" ] || { echo "hidden-role.sh: cannot read the brief $BRIEF" >&2; exit 2; }
valid_tag "$TAG" || { echo "hidden-role.sh: --tag must be non-empty and use only letters, digits, . _ -" >&2; exit 2; }
mkdir -p "$H"
[ ! -e "$H/$TAG.log" ] || { echo "tag $TAG was already used" >&2; exit 2; }
[ -n "${ORCA_TERMINAL_HANDLE:-}" ] || { echo "run this from the local coordinator's tab" >&2; exit 2; }

if hidden_live "$GITDIR" "$ROLE"; then echo "$ROLE is already running hidden" >&2; exit 1; fi
reap
rm -f "$H/$ROLE.stop"   # a stop that came too late must not fail the next run
if ! ( set -o noclobber; echo "starting - - - $TAG" > "$H/$ROLE.pid" ) 2>/dev/null; then echo "$ROLE is already running hidden" >&2; exit 1; fi
if ! detached_start "$H/$TAG.log" "$SELF" --supervise "$ROLE" "$BRIEF" "$TAG" "${RESUME:--}"; then
  rm -f "$H/$ROLE.pid"; echo "hidden-role.sh: could not start the run (no way to detach it)" >&2; exit 1
fi
echo "Started $TITLE hidden ($TAG); log: $H/$TAG.log"
