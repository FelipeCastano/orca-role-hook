#!/usr/bin/env bash
# Records one round of a worker (the Planner calls it after each Dev round, between dispatches; settings.flow.recordRounds).
# Usage (from the worktree):  round.sh <role|title> --step <step> --round <n> --outcome accepted|rejected|oracle-red [--task <id>]
# Each call appends one JSON line to <gitdir>/orca-roles.rounds.jsonl: ts, step, round, role, agent, model in effect, outcome, task, and the
# worktree's uncommitted change against HEAD (files, added, removed lines; cumulative for the set, since nothing is committed per step).
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,6p "$0"; exit 0;; esac
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
ROLEARG=""; STEP=""; ROUND=""; OUTCOME=""; TASK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --step|--round|--outcome|--task)
      [ -n "${2:-}" ] || { echo "round.sh: $1 needs a value" >&2; exit 1; }
      case "$1" in --step) STEP="$2";; --round) ROUND="$2";; --outcome) OUTCOME="$2";; --task) TASK="$2";; esac; shift;;
    -*) echo "round.sh: unknown option $1" >&2; exit 1;;
    *) [ -z "$ROLEARG" ] && ROLEARG="$1" || { echo "round.sh: only one role at a time" >&2; exit 1; };;
  esac
  shift
done
[ -n "$ROLEARG" ] && [ -n "$STEP" ] && [ -n "$ROUND" ] && [ -n "$OUTCOME" ] || { sed -n 4p "$0" >&2; exit 1; }
case "$OUTCOME" in accepted|rejected|oracle-red) ;; *) echo "round.sh: --outcome must be accepted, rejected or oracle-red" >&2; exit 1;; esac
case "$ROUND" in ''|*[!0-9]*) echo "round.sh: --round must be a number" >&2; exit 1;; esac
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "$STATE or $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
ID="$(resolve_role "$CFG" "$ROLEARG")"
[ -n "$ID" ] || { echo "Unknown role: $ROLEARG" >&2; exit 1; }
TITLE="$(title_of "$CFG" "$ID")"; LOG="$GITDIR/orca-roles.rounds.jsonl"
MODEL="$(rstr "$CFG" "$ID" model)"; AGENT="$(rstr "$CFG" "$ID" agent)"
FILES="$(git status --porcelain 2>/dev/null | grep -c . || true)"
NUM="$(git diff HEAD --numstat 2>/dev/null | awk '$1 != "-" {a += $1; r += $2} END {printf "%d %d", a, r}')" || NUM="0 0"
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg step "$STEP" --argjson round "$ROUND" --arg role "$ID" --arg agent "${AGENT:-claude}" \
  --arg model "$MODEL" --arg outcome "$OUTCOME" --arg task "$TASK" --argjson files "${FILES:-0}" \
  --argjson added "${NUM% *}" --argjson removed "${NUM#* }" \
  '{ts: $ts, step: $step, round: $round, role: $role, agent: $agent, model: $model, outcome: $outcome, task: $task,
    files: $files, added: $added, removed: $removed}' >> "$LOG" \
  || { echo "round.sh: could not write $LOG" >&2; exit 1; }
echo "Recorded round $ROUND of step $STEP for $TITLE ($MODEL): $OUTCOME."

