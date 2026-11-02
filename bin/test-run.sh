#!/usr/bin/env bash
# test-run.sh: runs a test command and adds the run to the kit's test log.
#   test-run.sh [--role <role>] [--label <text>] -- <command> [args...]
#   test-run.sh --path     print the resolved log path (an empty line when the log is off)
#   test-run.sh -h|--help  print this text
# The command runs in the foreground with this process's stdin, stdout and stderr; its output is not touched.
# Afterwards one JSON line is appended to the log and one line goes to stderr: test-run: exit <rc> in <s> s, <status>.
# Record: {ts, worktree, head, dirty, ncpu, role, label, kind:"run", cmd, exit, wall_s, load_start, load_end, result}.
# Log file: $ORCA_ROLES_TEST_LOG when set and not "off"; unset or empty: ${XDG_CACHE_HOME:-$HOME/.cache}/orca-roles/test-runs.jsonl;
# "off": nothing is written. A file over 5 MB is moved to <file>.1 first. Needs jq for the record (without it the command still runs).
# Environment assignments go before test-run.sh, not after --.
# The exit code is the command's; 2 is a usage error (nothing is run or logged).
set -uo pipefail

usage() { echo "test-run.sh: $1" >&2; exit 2; }

log_path() {
  case "${ORCA_ROLES_TEST_LOG:-}" in
    off) echo "" ;;
    '') echo "${XDG_CACHE_HOME:-${HOME:-/nonexistent}/.cache}/orca-roles/test-runs.jsonl" ;;
    *) echo "$ORCA_ROLES_TEST_LOG" ;;
  esac
}

load_now() {
  local l=""
  if [ -r /proc/loadavg ]; then
    read -r l _ < /proc/loadavg 2>/dev/null || l=""
  else
    l="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')"
  fi
  l="${l//,/.}"
  case "$l" in ''|*[!0-9.]*) l="" ;; esac
  printf '%s' "$l"
}

finish() {
  trap - INT TERM
  local rc="$1" ab="${2:-}" wall=$((SECONDS - T0)) l1 result status="log not written" line="" F dir
  l1="$(load_now)"
  if [ -n "$ab" ]; then result=aborted; elif [ "$rc" -eq 0 ]; then result=ok; else result=fail; fi
  F="$(log_path)"
  if [ -z "$F" ]; then
    status="log off"
  elif command -v jq >/dev/null 2>&1; then
    line="$(jq -nc --arg ts "$TS" --arg worktree "$WT" --arg head "$HEAD12" --argjson dirty "${DIRTY:-0}" --argjson ncpu "${NCPU:-1}" \
      --arg role "$ROLE" --arg label "$LABEL" --arg cmd "${CMD:0:300}" --argjson exit "$rc" --argjson wall_s "$wall" \
      --argjson ls "${L0:-null}" --argjson le "${l1:-null}" --arg result "$result" \
      '{ts:$ts,worktree:$worktree,head:$head,dirty:$dirty,ncpu:$ncpu,role:$role,label:$label,kind:"run",cmd:$cmd,exit:$exit,wall_s:$wall_s,load_start:$ls,load_end:$le,result:$result}' 2>/dev/null)" || line=""
    if [ -n "$line" ]; then
      dir="$(dirname "$F")"
      if { mkdir -p "$dir" \
        && { [ ! -f "$F" ] || [ "$(wc -c < "$F" | tr -d ' ')" -le 5242880 ] || mv -f "$F" "$F.1"; } \
        && printf '%s\n' "$line" >> "$F"; } 2>/dev/null; then status=logged; fi
    fi
  fi
  echo "test-run: exit $rc in $wall s, $status" >&2
  exit "$rc"
}

case "${1:-}" in
  -h|--help) sed -n 2,12p "$0"; exit 0 ;;
  --path) log_path; exit 0 ;;
esac

ROLE=""; LABEL=""; HAVE_ROLE=0; HAVE_LABEL=0; HAVE_SEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --) HAVE_SEP=1; shift; break ;;
    --role|--label)
      opt="$1"
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "$2" = -- ]; then usage "$opt needs one value"; fi
      if [ "$opt" = --role ]; then
        [ "$HAVE_ROLE" = 0 ] || usage "$opt needs one value"
        HAVE_ROLE=1; ROLE="$2"
      else
        [ "$HAVE_LABEL" = 0 ] || usage "$opt needs one value"
        HAVE_LABEL=1; LABEL="$2"
      fi
      shift 2 ;;
    *) usage "unknown option $1" ;;
  esac
done
[ "$HAVE_SEP" = 1 ] || usage "missing -- before the command"
[ $# -gt 0 ] || usage "no command after --"
if [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then usage "put environment assignments before test-run.sh, not after --"; fi

CMD="$*"
T0=$SECONDS TS="" L0="" WT="" HEAD12="" DIRTY=0 NCPU=1
trap 'finish 130 aborted' INT
trap 'finish 143 aborted' TERM
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
L0="$(load_now)"
WT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HEAD12="$(git -C "$WT" rev-parse --short=12 HEAD 2>/dev/null)"
DIRTY="$(git --no-optional-locks -C "$WT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
NCPU="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"

"$@"
finish $? ""
