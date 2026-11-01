#!/usr/bin/env bash
# Lists the worker_done reports of a Run whose body does not start with the report marker (Done, see REPORT_MARK_RE in lib.sh): a role
# that lost its prompt (a compaction, a wrong role message) stops writing it. Read-only for Orca: one 'orca orchestration inbox' read.
# Usage (from the worktree):  canary.sh --run <run_id> [--all] [--json]
#   By default only the reports not checked before (their ids are kept in <git dir>/orca-roles.canary-seen, the newest 1000).
#   The inbox lists only the last 200 messages of all Runs: if more arrived since this Run's last check, reports in between were never
#   seen; the script then says so (a "gap" line, exit 1) instead of reporting nothing.
#   --all checks every report of the Run that the inbox still lists and remembers nothing.
#   Text: one line per report without the marker: missing<TAB>created_at<TAB>role title (or "unknown")<TAB>handle<TAB>task id<TAB>first 80 characters
#   of the body (newlines and tabs as spaces); a possible gap adds one line gap<TAB><last sequence seen><TAB><oldest sequence listed>;
#   then "canary: <n> reports checked, <m> without the Done marker".
#   --json: {"checked": n, "gap": true|false, "missing": [{"id", "createdAt", "role", "title", "handle", "taskId", "start"}]}
# Exit 0: none missing and no gap; 1: some missing, or a possible gap; 2: usage error, no team in this folder, or Orca did not answer (nothing remembered).
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
USAGE="Usage: canary.sh --run <run_id> [--all] [--json]"
RUN=""; ALL=0; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; RUN="$2"; shift;;
    --all) ALL=1;;
    --json) JSON=1;;
    *) echo "$USAGE" >&2; exit 2;;
  esac
  shift
done
[ -n "$RUN" ] || { echo "$USAGE" >&2; exit 2; }
GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || GITDIR=""
[ -n "$GITDIR" ] && [ -s "$GITDIR/orca-roles.env" ] || { echo "canary: this folder has no orca-roles team" >&2; exit 2; }
CFG="$GITDIR/orca-roles.config.json"; [ -f "$CFG" ] || CFG=/dev/null
SEEN="$GITDIR/orca-roles.canary-seen"
IN="$(orca orchestration inbox --json --limit 200 2>/dev/null)"
printf '%s' "$IN" | jq -e '.result.messages | type == "array"' >/dev/null 2>&1 || { echo "canary: Orca did not answer 'orchestration inbox'" >&2; exit 2; }

SEEN_IDS="[]"; COVERED=null
if [ "$ALL" = 0 ] && [ -f "$SEEN" ]; then
  SEEN_IDS="$(jq -R -s -c 'split("\n") | map(select(length > 0 and (startswith("covered\t") | not)))' "$SEEN")"
  c="$(awk -F'\t' -v r="$RUN" '$1 == "covered" && $2 == r {v = $3} END {if (v != "") print v}' "$SEEN")"
  case "$c" in ''|*[!0-9]*) ;; *) COVERED="$c";; esac
fi
ROLES="[]"
while IFS='=' read -r var handle; do
  [ -n "$var" ] || continue
  id="$(printf '%s' "$var" | tr 'A-Z_' 'a-z-')"
  t="$(title_of "$CFG" "$id" 2>/dev/null)"
  ROLES="$(printf '%s' "$ROLES" | jq -c --arg r "$id" --arg t "${t:-$id}" --arg h "$handle" '. + [{role: $r, title: $t, handle: $h}]')"
done < "$GITDIR/orca-roles.env"

RES="$(printf '%s' "$IN" | jq -c --arg run "$RUN" --arg re "$REPORT_MARK_RE" --argjson seen "$SEEN_IDS" --argjson covered "$COVERED" --argjson roles "$ROLES" --argjson all "$ALL" '
  .result.messages as $m
  | ([$m[].sequence | numbers] | if length > 0 then {min: min, max: max} else {min: null, max: null} end) as $seq
  | [$m[] | select(.type == "worker_done" and .run_id == $run and ($all == 1 or (.id as $i | $seen | index($i) | not)))] | sort_by(.sequence) as $reps
  | {ids: [$reps[].id], maxSeq: $seq.max, minSeq: $seq.min,
     gap: ($all == 0 and $covered != null and $seq.min != null and $seq.min > $covered + 1),
     covered: $covered,
     checked: ($reps | length),
     missing: [$reps[] | select(((.body // "") | test($re; "i")) | not)
       | . as $r | ([$roles[] | select(.handle == $r.from_handle)] | first) as $ro
       | {id, createdAt: .created_at, role: ($ro.role // ""), title: ($ro.title // "unknown"), handle: (.from_handle // ""), taskId: (.payload.taskId // "-"),
          start: ((.body // "") | .[0:80] | gsub("[\n\r\t]"; " "))}]}')" || { echo "canary: could not read the inbox" >&2; exit 2; }

GAP="$(printf '%s' "$RES" | jq -r .gap)"; NMISS="$(printf '%s' "$RES" | jq '.missing | length')"; NCHK="$(printf '%s' "$RES" | jq .checked)"
if [ "$JSON" = 1 ]; then
  printf '%s' "$RES" | jq '{checked, gap, missing}'
else
  printf '%s' "$RES" | jq -r '.missing[] | ["missing", .createdAt, .title, .handle, .taskId, .start] | join("\t")'
  [ "$GAP" != true ] || printf '%s' "$RES" | jq -r '["gap", .covered, .minSeq] | map(tostring) | join("\t")'
  echo "canary: $NCHK reports checked, $NMISS without the Done marker"
fi
[ "$GAP" != true ] || echo "canary: more than 200 messages arrived since this Run's last check; reports in between were not checked" >&2

if [ "$ALL" = 0 ]; then
  {
    TMP="$(mktemp "$GITDIR/orca-roles.canary-seen.XXXXXX")" &&
    {
      [ ! -f "$SEEN" ] || awk -F'\t' -v r="$RUN" 'length > 0 && !($1 == "covered" && $2 == r)' "$SEEN"
      printf '%s' "$RES" | jq -r '.ids[]'
      printf '%s' "$RES" | jq -r --arg run "$RUN" 'select(.maxSeq != null) | "covered\t\($run)\t\(.maxSeq)"'
    } | tail -n 1000 > "$TMP" && mv "$TMP" "$SEEN"
  } || echo "canary: could not write $SEEN" >&2
fi
[ "$GAP" != true ] && [ "$NMISS" -eq 0 ]
