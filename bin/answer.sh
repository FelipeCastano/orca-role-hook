#!/usr/bin/env bash
# Answers one question: 'orca orchestration reply' to it and, when it was asked from a dispatch, the same text sent to that dispatch as a
# fallback against a lost wake notice. R1 measured on Orca 1.4.257 that reply alone woke the asker (2 of 2), so the extra send is a fallback,
# not a cure: the 2026-11-14 stalls were not reproduced, and this script does not claim that reply alone fails to wake.
# Usage (from the worktree):  answer.sh --id <msg_id> (--body <text> | --body-file <file>)
#   The text reaches reply and the fallback send unchanged (multi-line text included).
#   Text: "answer: replied to <msg_id>."; then "answer: sent the same text to dispatch:<ctx>.", or
#   "answer: send to dispatch:<ctx> failed (exit <n>); the reply was delivered.", or "answer: <msg_id> was not asked from a dispatch; reply
#   only.", or "answer: <msg_id> not found in the inbox; reply only.".
# Exit 0: the reply succeeded (whatever the send did); 1: the reply failed, nothing sent; 2: usage error (nothing called).
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
USAGE="Usage: answer.sh --id <msg_id> (--body <text> | --body-file <file>)"
ID=""; BODY=""; BF=""; id_set=0; body_set=0; bf_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --id) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; ID="$2"; id_set=1; shift;;
    --body) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; BODY="$2"; body_set=1; shift;;
    --body-file) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; BF="$2"; bf_set=1; shift;;
    *) echo "$USAGE" >&2; exit 2;;
  esac
  shift
done
[ "$id_set" = 1 ] && [ -n "$ID" ] || { echo "$USAGE" >&2; exit 2; }
[ "$body_set" = 0 ] || [ "$bf_set" = 0 ] || { echo "$USAGE" >&2; exit 2; }
[ "$body_set" = 1 ] || [ "$bf_set" = 1 ] || { echo "$USAGE" >&2; exit 2; }
if [ "$bf_set" = 1 ]; then
  [ -r "$BF" ] || { echo "answer: cannot read $BF" >&2; exit 2; }
  BODY="$(cat "$BF")" || exit 2
fi

ROUT="$(orca orchestration reply --id "$ID" --body "$BODY" --json 2>&1)"; RRC=$?
if [ "$RRC" != 0 ]; then
  printf '%s\n' "$ROUT"
  echo "answer: reply to $ID failed (exit $RRC); nothing sent."
  exit 1
fi
echo "answer: replied to $ID."

IN="$(orca orchestration inbox --json --full --limit 2000 2>&1)" || IN=""
if ! printf '%s' "$IN" | jq -e '.result.messages | type == "array"' >/dev/null 2>&1; then
  echo "answer: $ID not found in the inbox; reply only."
  exit 0
fi
CTX="$(printf '%s' "$IN" | jq -r --arg id "$ID" '
  .result.messages as $m
  | ([$m[] | select((.subject // "") == "Re: Question" and (.thread_id // "") == $id)] | sort_by(.created_at // "") | last) as $r
  | ($r.to_handle // "") as $to
  | ([$m[] | select((.id // "") == $id)] | last) as $q
  | ($q.payload | if type == "string" then (try fromjson catch null) else . end) as $p
  | if ($to | startswith("dispatch:")) then $to[9:]
    elif (($q.from_handle // "") | startswith("dispatch:")) then ($q.from_handle)[9:]
    elif (($p | type) == "object" and (($p.dispatchId // "") | length) > 0) then $p.dispatchId
    else "" end' 2>/dev/null)" || CTX=""
if [ -z "$CTX" ]; then
  if ! printf '%s' "$IN" | jq -e --arg id "$ID" '[.result.messages[] | select((.id // "") == $id)] | length > 0' >/dev/null 2>&1; then
    echo "answer: $ID not found in the inbox; reply only."
  else
    echo "answer: $ID was not asked from a dispatch; reply only."
  fi
  exit 0
fi
SOUT="$(orca orchestration send --to "dispatch:$CTX" --subject "Answer to $ID" --body "$BODY" --json 2>&1)"; SRC=$?
if [ "$SRC" != 0 ]; then
  printf '%s\n' "$SOUT"
  echo "answer: send to dispatch:$CTX failed (exit $SRC); the reply was delivered."
  exit 0
fi
echo "answer: sent the same text to dispatch:$CTX."
exit 0
