#!/usr/bin/env bash
# After one worker_done: runs the canary, compacts the Planner when asked, and prints the report path with the lines the coordinator has to
# read (needs: blocks and Decisions sections) instead of the whole report.
# Usage (from the worktree):  on-done.sh --dispatch <dispatch_id> --run <run_id> [--role planner] [--no-release]
#   --no-release: accepted for older prompts; does nothing (on Orca 1.4.259 a release of a kit tab's dispatch was reported to answer retained/external_terminal and do nothing).
#   --role planner: also runs compact-role.sh planner --if-above 200000 with the instructions the local coordinator prompt names.
#   Text: nothing when every step succeeds; otherwise the failing step's own output and one line naming it. Then "report: <path>" and, for a
#   readable report, its needs: blocks and its Decisions sections in file order; "report: none in <message id>; its body follows:" plus the
#   body when the worker_done names no path, "report: none found for <dispatch_id>" when no worker_done matches, and
#   "report: <path> (not readable)".
# Overrides for tests: ORCA_ROLES_CANARY (the canary script), ORCA_ROLES_COMPACT (the compact script).
# Exit 0: every step that ran succeeded and the report was found; 1: a step failed or the report is missing/unreadable; 2: usage error.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
USAGE="Usage: on-done.sh --dispatch <dispatch_id> --run <run_id> [--role planner] [--no-release]"
DISPATCH=""; RUN=""; ROLE=""; dis_set=0; run_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dispatch) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; DISPATCH="$2"; dis_set=1; shift;;
    --run) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; RUN="$2"; run_set=1; shift;;
    --role) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; ROLE="$2"; shift;;
    --no-release) :;;
    *) echo "$USAGE" >&2; exit 2;;
  esac
  shift
done
[ "$dis_set" = 1 ] && [ -n "$DISPATCH" ] || { echo "$USAGE" >&2; exit 2; }
[ "$run_set" = 1 ] && [ -n "$RUN" ] || { echo "$USAGE" >&2; exit 2; }
case "$ROLE" in ''|planner) ;; *) echo "$USAGE" >&2; exit 2;; esac

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/orca-roles-on-done.XXXXXX")" || exit 1
trap 'rm -rf "$TMPD"' EXIT
FAIL=0

CANARY="${ORCA_ROLES_CANARY:-$KIT/bin/canary.sh}"
"$CANARY" --run "$RUN" > "$TMPD/canary.out" 2> "$TMPD/canary.err"; CRC=$?
if [ "$CRC" != 0 ]; then
  FAIL=1
  cat "$TMPD/canary.out" "$TMPD/canary.err"
fi

if [ "$ROLE" = planner ]; then
  COMPACT="${ORCA_ROLES_COMPACT:-$KIT/bin/compact-role.sh}"
  "$COMPACT" planner --if-above 200000 --instructions "Keep verbatim the current plan (its file paths and steps), the open findings, every Ruling (Planner): line and every answer of the user; summarize the rest." > "$TMPD/compact.out" 2>&1; KRC=$?
  COUT="$(cat "$TMPD/compact.out")"
  if [ "$KRC" = 0 ]; then
    case "$COUT" in *"
"*) printf '%s\n' "$COUT";; *': not compacted') :;; *) [ -z "$COUT" ] || printf '%s\n' "$COUT";; esac
  else
    FAIL=1
    [ -z "$COUT" ] || printf '%s\n' "$COUT"
    echo "on-done: compact-role.sh failed (exit $KRC)."
  fi
fi

IN="$(orca orchestration inbox --terminal "run:$RUN" --json --full --limit 200 2>&1)"; IRC=$?
if [ "$IRC" != 0 ] || ! printf '%s' "$IN" | jq -e '.result.messages | type == "array"' >/dev/null 2>&1; then
  echo "report: none found for $DISPATCH"
  FAIL=1
else
  MSG="$(printf '%s' "$IN" | jq -c --arg d "$DISPATCH" '
    [.result.messages[] | select(.type == "worker_done")
     | .payload as $p
     | ($p | if type == "string" then (try fromjson catch null) else . end) as $q
     | select(($q | type) == "object" and ($q.dispatchId // "") == $d)] as $m
    | $m | sort_by(.created_at // "") | if length > 0 then .[-1] else null end' 2>/dev/null)" || MSG=""
  if [ -z "$MSG" ] || [ "$MSG" = null ]; then
    echo "report: none found for $DISPATCH"
    FAIL=1
  else
    PATHV="$(printf '%s' "$MSG" | jq -r '.payload | if type == "string" then (try fromjson catch null) else . end | if type == "object" then (.reportPath // "") else "" end' 2>/dev/null)" || PATHV=""
    if [ -z "$PATHV" ]; then
      PATHV="$(printf '%s' "$MSG" | jq -r '.body // ""' 2>/dev/null | awk 'index($0, "Report: ") { p = substr($0, index($0, "Report: ") + 8); sub(/[ \t\r]+$/, "", p); print p; exit }')"
    fi
    if [ -z "$PATHV" ]; then
      printf 'report: none in %s; its body follows:\n' "$(printf '%s' "$MSG" | jq -r '.id // ""')"
      printf '%s' "$MSG" | jq -r '
        (.body // "") as $b
        | if ($b | length) == 0 then empty
          else ($b[0:2000] | split("\n") | map("  " + .)[]),
               (if ($b | length) > 2000
                then "  … (cut at 2000 characters; whole: orca orchestration inbox --terminal \(.to_handle // "") --full --json, id \(.id // ""))"
                else empty end)
          end'
    elif [ ! -f "$PATHV" ] || [ ! -r "$PATHV" ]; then
      echo "report: $PATHV (not readable)"
      FAIL=1
    else
      echo "report: $PATHV"
      awk '
        function is_heading(s) { return s ~ /^[ \t]*#{1,6}[ \t]/ }
        function hlevel(s,   t) { t = s; sub(/^[ \t]*/, "", t); match(t, /^#+/); return RLENGTH }
        function ends_at(j) { return lines[j] ~ /^[ \t]*$/ || is_heading(lines[j]) }
        BEGIN {
          bq = sprintf("%c", 96)
          pre = "^[ \t]*([-*+]|[0-9]+[.)])?[ \t]*(\\*\\*)?(" bq ")?"
          re_needs = pre "[Nn][Ee][Ee][Dd][Ss]:"
          re_dec = pre "[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn][Ss]?(\\*\\*)?:"
          re_dec_word = "(^|[^A-Za-z])[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn][Ss]?([^A-Za-z]|$)"
        }
        { lines[NR] = $0 }
        END {
          n = NR
          for (i = 1; i <= n; i++) {
            if (lines[i] ~ re_needs) {
              mark[i] = 1
              for (j = i + 1; j <= n; j++) { if (ends_at(j)) break; mark[j] = 1 }
            }
            if (is_heading(lines[i])) {
              t = lines[i]; sub(/^[ \t]*#+[ \t]*/, "", t)
              if (t ~ re_dec_word) {
                lvl = hlevel(lines[i]); mark[i] = 1
                for (j = i + 1; j <= n; j++) { if (is_heading(lines[j]) && hlevel(lines[j]) <= lvl) break; mark[j] = 1 }
              }
            }
            if (lines[i] ~ re_dec) {
              mark[i] = 1
              for (j = i + 1; j <= n; j++) { if (ends_at(j)) break; mark[j] = 1 }
            }
          }
          for (i = 1; i <= n; i++) if (mark[i]) print lines[i]
        }' "$PATHV"
    fi
  fi
fi
[ "$FAIL" = 0 ] || exit 1
exit 0
