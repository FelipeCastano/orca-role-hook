#!/usr/bin/env bash
# Records one round of a worker (the Planner calls it after each Dev round, between dispatches; settings.flow.recordRounds) and, when
# settings.flow.escalation names a model for that role, escalates it after rejected rounds and brings it back when the step is accepted.
# Usage (from the worktree):  round.sh <role|title> --step <step> --round <n> --outcome accepted|rejected|oracle-red [--task <id>]
#                             [--cross agree|disagree|none]
# Each call appends one JSON line to the repository's orca-roles.rounds.jsonl, in the git common dir so it outlives the worktree: ts,
# worktree (its branch), step, round, role, agent, model in effect, outcome, task, and the worktree's uncommitted change against HEAD
# (files, added, removed lines; cumulative for the set, since nothing is committed per step), and, with --cross, the Tester's cross-check
# result for that round (settings.flow.crossCheck; none when it had no candidate).
# Escalation (settings.flow.escalation.<role> = {"to": "<model>", "after": N}, programmer mode): once a step has N rejected or oracle-red
# rounds (default 1) the role is relaunched on "to" with relaunch-role.sh; the first accepted round brings it back to its model.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,11p "$0"; exit 0;; esac
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
ROLEARG=""; STEP=""; ROUND=""; OUTCOME=""; TASK=""; CROSS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --step|--round|--outcome|--task|--cross)
      [ -n "${2:-}" ] || { echo "round.sh: $1 needs a value" >&2; exit 1; }
      case "$1" in --step) STEP="$2";; --round) ROUND="$2";; --outcome) OUTCOME="$2";; --task) TASK="$2";; --cross) CROSS="$2";; esac; shift;;
    -*) echo "round.sh: unknown option $1" >&2; exit 1;;
    *) [ -z "$ROLEARG" ] && ROLEARG="$1" || { echo "round.sh: only one role at a time" >&2; exit 1; };;
  esac
  shift
done
[ -n "$ROLEARG" ] && [ -n "$STEP" ] && [ -n "$ROUND" ] && [ -n "$OUTCOME" ] || { sed -n 4,5p "$0" >&2; exit 1; }
case "$OUTCOME" in accepted|rejected|oracle-red) ;; *) echo "round.sh: --outcome must be accepted, rejected or oracle-red" >&2; exit 1;; esac
case "$ROUND" in ''|*[!0-9]*) echo "round.sh: --round must be a number" >&2; exit 1;; esac
case "$CROSS" in ''|agree|disagree|none) ;; *) echo "round.sh: --cross must be agree, disagree or none" >&2; exit 1;; esac
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "$STATE or $CFG not found: run this from the worktree where the roles were opened." >&2; exit 1; }
ID="$(resolve_role "$CFG" "$ROLEARG")"
[ -n "$ID" ] || { echo "Unknown role: $ROLEARG" >&2; exit 1; }
COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo "$GITDIR")"; COMMON="$(cd "$COMMON" && pwd)"
WTB="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
TITLE="$(title_of "$CFG" "$ID")"; LOG="$COMMON/orca-roles.rounds.jsonl"; ESC="$GITDIR/orca-roles.escalation"
MODEL="$(rstr "$CFG" "$ID" model)"; AGENT="$(rstr "$CFG" "$ID" agent)"
FILES="$(git status --porcelain 2>/dev/null | grep -c . || true)"
NUM="$(git diff HEAD --numstat 2>/dev/null | awk '$1 != "-" {a += $1; r += $2} END {printf "%d %d", a, r}')" || NUM="0 0"
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg wt "$WTB" --arg step "$STEP" --argjson round "$ROUND" --arg role "$ID" --arg agent "${AGENT:-claude}" \
  --arg model "$MODEL" --arg outcome "$OUTCOME" --arg task "$TASK" --argjson files "${FILES:-0}" \
  --argjson added "${NUM% *}" --argjson removed "${NUM#* }" --arg cross "$CROSS" \
  '{ts: $ts, worktree: $wt, step: $step, round: $round, role: $role, agent: $agent, model: $model, outcome: $outcome, task: $task,
    files: $files, added: $added, removed: $removed} + (if $cross == "" then {} else {cross: $cross} end)' >> "$LOG" \
  || { echo "round.sh: could not write $LOG" >&2; exit 1; }
echo "Recorded round $ROUND of step $STEP for $TITLE ($MODEL): $OUTCOME."

# Escalation. The state file holds one line per escalated role: <role> <tab> <step> <tab> <model it had before>.
TO=""; AFTER=1
if [ "$(mode_of "$CFG")" = programmer ]; then read -r TO AFTER <<< "$(flow_escalation "$CFG" "$ID")"; fi
[ -n "$TO" ] || exit 0
escalated_from() { [ -f "$ESC" ] && awk -F'\t' -v r="$1" '$1 == r {print $3; exit}' "$ESC"; }
FROM="$(escalated_from "$ID")"
if [ "$OUTCOME" = accepted ]; then
  [ -n "$FROM" ] || exit 0
  if [ "$FROM" != "$MODEL" ]; then
    "$KIT/bin/relaunch-role.sh" "$ID" --model "$FROM" || { echo "Could not bring $TITLE back to $FROM; it stays on $MODEL (run relaunch-role.sh $ID --model $FROM)." >&2; exit 4; }
  fi
  awk -F'\t' -v r="$ID" '$1 != r' "$ESC" > "$ESC.tmp" && mv "$ESC.tmp" "$ESC"
  echo "Step accepted: $TITLE is back on $FROM. Use its new handle from now on."
  exit 0
fi
[ -z "$FROM" ] || exit 0          # already escalated in this step
[ "$MODEL" != "$TO" ] || exit 0   # its own model is already the escalation model
N="$(jq -s --arg w "$WTB" --arg s "$STEP" --arg r "$ID" '[.[] | select(.worktree == $w and .step == $s and .role == $r and .outcome != "accepted")] | length' "$LOG" 2>/dev/null || echo 0)"
[ "$N" -ge "$AFTER" ] || exit 0
"$KIT/bin/relaunch-role.sh" "$ID" --model "$TO" || { echo "Could not escalate $TITLE to $TO; it stays on $MODEL." >&2; exit 4; }
printf '%s\t%s\t%s\n' "$ID" "$STEP" "$MODEL" >> "$ESC"
echo "Escalated $TITLE from $MODEL to $TO after $N rejected round(s) of step $STEP; it comes back to $MODEL when the step is accepted. Use its new handle from now on."
