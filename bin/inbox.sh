#!/usr/bin/env bash
# Reads every pending message batch of a Run and prints one line per message, plus the bodies that need reading, acknowledging the older-Orca
# batches as it goes; it replaces the raw JSON of the coordinator's `check` loop. Read: 'orca orchestration check [--run] --json --full' until
# the batch is empty, and 'check --ack <deliveryId> --json --full' when a batch carries a delivery id.
# Usage (from the worktree):  inbox.sh [--run <run_id>]
#   Text: per message one tab-separated line <type> <role> <from handle> <subject> <verdict> <outcome> <report path> <message id> <task id>
#   <dispatch id> ("-" for an empty field), then two-space-indented body lines for every message but a worker_done that names a report; a body
#   over 2000 characters is cut with a line that names the inbox command showing it whole. Last line: "inbox: <n> message(s)".
#   The role is the team state's id whose handle is the sender (ORCA_ROLES_STATE, else <git dir>/orca-roles.env); "-" when there is no state.
# Exit 0: every batch read; 1: a check/ack failed or a batch could not be read (its raw output is printed); 2: usage error.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
USAGE="Usage: inbox.sh [--run <run_id>]"
RUN=""; run_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; RUN="$2"; run_set=1; shift;;
    *) echo "$USAGE" >&2; exit 2;;
  esac
  shift
done
GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || GITDIR=""
STATE="${ORCA_ROLES_STATE:-${GITDIR:+$GITDIR/orca-roles.env}}"
[ -n "$STATE" ] && [ -f "$STATE" ] || STATE=""

role_of() {  # role_of <handle>: the id of the team state's line holding it, or nothing
  local var=""
  [ -n "$STATE" ] || return 0
  var="$(awk -F= -v h="$1" '$2 == h { print $1; exit }' "$STATE" 2>/dev/null)"
  [ -n "$var" ] || return 0
  printf '%s' "$var" | tr 'A-Z_' 'a-z-'
}

print_body() {  # print_body <json message>: its body as two-space-indented lines, cut at 2000 characters
  printf '%s' "$1" | jq -r '
    (.body // "") as $b
    | if ($b | length) == 0 then empty
      else ($b[0:2000] | split("\n") | map("  " + .)[]),
           (if ($b | length) > 2000
            then "  … (cut at 2000 characters; whole: orca orchestration inbox --terminal \(.to_handle // "") --full --json, id \(.id // ""))"
            else empty end)
      end'
}

clean_field() {  # clean_field <text>: one line, no tabs, "-" when empty
  local v
  v="$(printf '%s' "$1" | tr '\t\n\r' '   ')"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' '-'
}

print_batch() {  # print_batch <json batch>: every message's header and body, in Orca's order
  local n i m pl from type subj id report task disp role verdict body path outcome
  n="$(printf '%s' "$1" | jq '.result.messages | length' 2>/dev/null)" || return 1
  for ((i = 0; i < n; i++)); do
    m="$(printf '%s' "$1" | jq -c ".result.messages[$i]" 2>/dev/null)" || return 1
    pl="$(printf '%s' "$m" | jq -c '.payload | if type == "string" then (try fromjson catch null) else . end | if type == "object" then . else null end' 2>/dev/null)" || pl=null
    [ "$pl" = null ] || [ -n "$pl" ] || pl=null
    from="$(printf '%s' "$m" | jq -r '.from_handle // ""' 2>/dev/null)" || from=""
    type="$(clean_field "$(printf '%s' "$m" | jq -r '.type // ""' 2>/dev/null)")"
    subj="$(printf '%s' "$m" | jq -r '.subject // ""' 2>/dev/null)" || subj=""
    id="$(clean_field "$(printf '%s' "$m" | jq -r '.id // ""' 2>/dev/null)")"
    verdict="-"; outcome="-"
    case "$subj" in "VERDICT: "*) verdict="$(clean_field "${subj#VERDICT: }")";; esac
    role="$(role_of "$from")"; role="$(clean_field "$role")"
    if [ "$pl" = null ]; then
      report=""; task=""; disp=""
    else
      report="$(printf '%s' "$pl" | jq -r '.reportPath // "" | tostring' 2>/dev/null)" || report=""
      task="$(printf '%s' "$pl" | jq -r '.taskId // "" | tostring' 2>/dev/null)" || task=""
      disp="$(printf '%s' "$pl" | jq -r '.dispatchId // "" | tostring' 2>/dev/null)" || disp=""
      outcome="$(clean_field "$(printf '%s' "$pl" | jq -r '.outcome // ""' 2>/dev/null)")"
    fi
    body="$(printf '%s' "$m" | jq -r '.body // ""' 2>/dev/null)" || body=""
    if [ "$type" = worker_done ] && [ -z "$report" ]; then
      path="$(printf '%s' "$body" | awk 'index($0, "Report: ") { p = substr($0, index($0, "Report: ") + 8); sub(/[ \t\r]+$/, "", p); print p; exit }')"
      [ -z "$path" ] || report="$path"
    fi
    [ -n "$disp" ] || case "$from" in dispatch:*) disp="${from#dispatch:}";; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$type" "$role" "$(clean_field "$from")" "$(clean_field "$subj")" "$verdict" "${outcome:--}" \
      "$(clean_field "$report")" "$id" "$(clean_field "$task")" "$(clean_field "$disp")"
    TOTAL=$((TOTAL + 1))
    if [ "$type" = worker_done ] && [ -n "$report" ]; then :; else print_body "$m"; fi
  done
  return 0
}

TOTAL=0; STATUS=0; BATCHES=0; ACK=""
while :; do
  if [ "$BATCHES" -ge 50 ]; then echo "inbox: stopped after 50 batches; run it again."; exit 1; fi
  BATCHES=$((BATCHES + 1))
  CHK=(check)
  [ "$run_set" = 0 ] || CHK+=(--run "$RUN")
  CALL_ACK="$ACK"
  [ -z "$CALL_ACK" ] || CHK+=(--ack "$CALL_ACK")
  CHK+=(--json --full)
  OUT="$(orca orchestration "${CHK[@]}" 2>&1)"; RC=$?
  if [ "$RC" != 0 ]; then
    printf '%s\n' "$OUT"
    if [ -n "$CALL_ACK" ]; then echo "inbox: ack of $CALL_ACK failed."
    else echo "inbox: orca orchestration check failed (exit $RC)."; fi
    exit 1
  fi
  if ! printf '%s' "$OUT" | jq -e '.result.messages | type == "array"' >/dev/null 2>&1; then
    echo "inbox: could not read a batch; its raw output follows."
    printf '%s\n' "$OUT"
    STATUS=1
    ACK="$(printf '%s' "$OUT" | jq -r '.result.deliveryId // empty | select(type == "string")' 2>/dev/null)" || ACK=""
    if [ -n "$ACK" ]; then continue; fi
    break
  fi
  N="$(printf '%s' "$OUT" | jq '.result.messages | length')"
  if [ "$N" = 0 ]; then break; fi
  print_batch "$OUT" || {
    echo "inbox: could not read a batch; its raw output follows."
    printf '%s\n' "$OUT"
    STATUS=1
    ACK="$(printf '%s' "$OUT" | jq -r '.result.deliveryId // empty | select(type == "string")' 2>/dev/null)" || ACK=""
    if [ -n "$ACK" ]; then continue; fi
    break
  }
  ACK="$(printf '%s' "$OUT" | jq -r '.result.deliveryId // empty | select(type == "string")' 2>/dev/null)" || ACK=""
  [ -n "$ACK" ] || ACK=""
done
echo "inbox: $TOTAL message(s)"
exit "$STATUS"
