#!/usr/bin/env bash
# Routine Dev→Tester handoff of one batch round: records the worktree as it is (bin/checkpoint.sh), writes the Tester brief from a fixed
# template (spec path, Dev's report, base and diff refs, changed files), appends the set's ledger line, creates the Tester task
# (orca orchestration task-create) and dispatches it (bin/dispatch.sh), so the local coordinator runs one command after Dev's report.
# Usage (from the worktree):  handoff.sh <batch> --to <tester handle> --run <run_id> --spec <spec path> --report <Dev report path>
#                             [--tree <pair tree path>] [--note <text>]
# <batch> is [a-z0-9-]+ (starting with a letter or digit). Round 1 of a batch diffs from the batch's base; a later round diffs from the
# previous round's checkpoint and keeps that base. Options come in any order, each with one value.
# Writes: the brief at <local coordinator's scratch>/briefs/<batch>-r<k>.md, one line in that folder's ledger.md, and the round's line
# <batch> <k> <ref> <base> in <git dir>/orca-roles.handoff.
# Exit codes: 0 done; 1 usage or a bad argument, nothing done; 3 checkpoint failed; 4 task-create failed; 5 dispatch failed.
# On 3, 4 and 5 nothing is dispatched and stderr says what was recorded. ORCA_ROLES_DISPATCH replaces dispatch.sh (the tests).
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
case "${1:-}" in -h|--help) sed -n 2,12p "$0"; exit 0;; esac
usage() { sed -n 4,5p "$0" >&2; exit 1; }
abspath() {  # abspath <path>: the path as given, with its folder resolved
  local d b
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  b="$(basename "$1")"
  if [ "$d" = / ]; then printf '/%s' "$b"; else printf '%s/%s' "$d" "$b"; fi
}
BATCH=""; TO=""; RUN=""; SPEC=""; REPORT=""; TREE=""; NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to|--run|--spec|--report|--tree|--note)
      [ -n "${2:-}" ] || { echo "handoff.sh: $1 needs a value" >&2; usage; }
      case "$1" in
        --to) TO="$2";;
        --run) RUN="$2";;
        --spec) SPEC="$2";;
        --report) REPORT="$2";;
        --tree) TREE="$2";;
        --note) NOTE="$2";;
      esac
      shift;;
    -*) echo "handoff.sh: unknown option $1" >&2; usage;;
    *) if [ -z "$BATCH" ]; then BATCH="$1"; else echo "handoff.sh: only one batch at a time" >&2; usage; fi;;
  esac
  shift
done
[ -n "$BATCH" ] && [ -n "$TO" ] && [ -n "$RUN" ] && [ -n "$SPEC" ] && [ -n "$REPORT" ] || usage
[[ "$BATCH" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "handoff.sh: invalid batch '$BATCH'" >&2; exit 1; }
[ -f "$SPEC" ] && [ -r "$SPEC" ] || { echo "handoff.sh: $SPEC is not a readable file" >&2; exit 1; }
[ -f "$REPORT" ] && [ -r "$REPORT" ] || { echo "handoff.sh: $REPORT is not a readable file" >&2; exit 1; }
if [ -n "$TREE" ] && [ ! -d "$TREE" ]; then echo "handoff.sh: $TREE is not a directory" >&2; exit 1; fi
SPEC="$(abspath "$SPEC")" || { echo "handoff.sh: cannot resolve $SPEC" >&2; exit 1; }
REPORT="$(abspath "$REPORT")" || { echo "handoff.sh: cannot resolve $REPORT" >&2; exit 1; }
[ -z "$TREE" ] || TREE="$(abspath "$TREE")"

CS="$(scratch_dir local-coordinator)" || true
[ -n "$CS" ] || { echo "handoff.sh: cannot find the local coordinator's scratch folder" >&2; exit 1; }
BRIEF_DIR="$CS/briefs"; LEDGER="$CS/ledger.md"
GITDIR="$(git rev-parse --git-dir 2>/dev/null)" && GITDIR="$(cd "$GITDIR" && pwd)" || GITDIR=""
STATE="${GITDIR:+$GITDIR/orca-roles.handoff}"

# Round k, FROM and BASE: the batch's last round in the state file, or round 1 when the batch is new or its last ref is gone
K=1; FROM=""; BASE=""
if [ -n "$STATE" ] && [ -f "$STATE" ]; then
  LASTREF="$(awk -F'\t' -v b="$BATCH" '$1 == b { r = $3 } END { print r }' "$STATE")"
  if [ -n "$LASTREF" ] && git show-ref --verify --quiet "$LASTREF" 2>/dev/null; then
    K="$(awk -F'\t' -v b="$BATCH" '$1 == b { k = $2 + 1 } END { print k }' "$STATE")"
    FROM="$LASTREF"
    BASE="$(awk -F'\t' -v b="$BATCH" '$1 == b && !c { x = $4; c = 1 } END { print x }' "$STATE")"
  elif [ -n "$LASTREF" ]; then
    awk -F'\t' -v b="$BATCH" '$1 != b' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  fi
fi

TREE_RUN="${TREE:-.}"
N="$(cd "$TREE_RUN" 2>/dev/null && "$KIT/bin/checkpoint.sh" --list "$BATCH" 2>/dev/null | grep -c .)" || true
N=$(( N + 1 ))
CP_OUT="$(cd "$TREE_RUN" && "$KIT/bin/checkpoint.sh" "$BATCH" "$N")"; CP_RC=$?
if [ "$CP_RC" != 0 ]; then echo "handoff.sh: checkpoint failed; nothing recorded, nothing dispatched" >&2; exit 3; fi
REF="$(printf '%s\n' "$CP_OUT" | sed -n 1p)"
[ -n "$REF" ] || { echo "handoff.sh: checkpoint failed; nothing recorded, nothing dispatched" >&2; exit 3; }
if [ "$K" = 1 ]; then
  X="$(printf '%s\n' "$CP_OUT" | sed -n 's/^Whole step since \(.*\) (the first brief):  git diff .*$/\1/p' | head -1)"
  [ -n "$X" ] || X="$(printf '%s\n' "$CP_OUT" | sed -n 's/^Whole set since the branch base (\(.*\)):  git diff .*$/\1/p' | head -1)"
  if [ "$X" = HEAD ]; then X="$(cd "$TREE_RUN" && git rev-parse HEAD 2>/dev/null)"; fi
  if [ -z "$X" ]; then echo "handoff.sh: no base ref for $BATCH; checkpoint $REF recorded, nothing dispatched" >&2; exit 3; fi
  FROM="$X"; BASE="$X"
fi

FILES="$(cd "$TREE_RUN" && git diff --name-only "$FROM" "$REF" | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')"
[ -n "$FILES" ] || FILES="none"
mkdir -p "$BRIEF_DIR" 2>/dev/null
BRIEF="$BRIEF_DIR/$BATCH-r$K.md"
{
  printf 'Tester round %s of %s.\n' "$K" "$BATCH"
  printf 'Spec: %s\n' "$SPEC"
  printf "Dev's report: %s\n" "$REPORT"
  printf 'Base ref (for the base check): %s\n' "$BASE"
  printf 'Diff to review: git diff %s %s\n' "$FROM" "$REF"
  printf 'Files changed: %s\n' "$FILES"
  if [ -n "$TREE" ]; then printf 'Tree: %s\n' "$TREE"; fi
  if [ -n "$NOTE" ]; then printf 'Notes from the local coordinator: %s\n' "$NOTE"; fi
  if [ "$K" -gt 1 ]; then printf 'Earlier rounds of this batch: %s (its lines for %s, and the Tester reports they name).\n' "$LEDGER" "$BATCH"; fi
} > "$BRIEF"
ledger() {  # ledger <end of the line>
  printf -- '- %s %s round %s: checkpoint %s; Dev report %s; brief %s; %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BATCH" "$K" "$REF" "$REPORT" "$BRIEF" "$1" >> "$LEDGER"
}

TC_OUT="$(orca orchestration task-create --spec-file "$BRIEF" --task-title "Tester $BATCH round $K" --run "$RUN" --json)"
TC_RC=$?
TASK_ID="$(printf '%s' "$TC_OUT" | jq -r 'select(.ok == true and .result.status == "ready") | .result.taskId' 2>/dev/null)"
if [ "$TC_RC" != 0 ] || [ -z "$TASK_ID" ]; then
  ledger "Tester task not created (exit $TC_RC)"
  echo "handoff.sh: task-create failed (exit $TC_RC); recorded: checkpoint $REF, brief $BRIEF, ledger line; nothing dispatched" >&2
  exit 4
fi
"${ORCA_ROLES_DISPATCH:-$KIT/bin/dispatch.sh}" --task "$TASK_ID" --to "$TO" --run "$RUN" >&2
DS_RC=$?
if [ "$DS_RC" != 0 ]; then
  ledger "Tester task $TASK_ID not dispatched (exit $DS_RC)"
  echo "handoff.sh: dispatch failed (exit $DS_RC); recorded: checkpoint $REF, brief $BRIEF, ledger line; nothing dispatched" >&2
  exit 5
fi
ledger "Tester task $TASK_ID dispatched"
[ -z "$STATE" ] || printf '%s\t%s\t%s\t%s\n' "$BATCH" "$K" "$REF" "$BASE" >> "$STATE"
printf 'handoff: checkpoint %s\n' "$REF"
printf 'handoff: %s round %s task %s brief %s\n' "$BATCH" "$K" "$TASK_ID" "$BRIEF"
exit 0
