#!/usr/bin/env bash
# What each role of a worktree's team is doing, from what Orca tracks (no agent is asked).  Read-only.
# Usage:  team-status.sh [--json] [--run <run_id>] [<worktree folder>]     (default folder: the current directory)
#   One line per role, tab-separated: Title, state, since, task, tool, summary.
#   state: working | waiting (waiting for an answer or a permission) | done | interrupted | failed | no-status (Orca has no row for
#          the tab) | no-tab (no tab saved) | undelivered (--run only: done, and a dispatch of the run is open but never started and its
#          text sits in the composer: Enter lost)
#   since: age of that state (45s, 12m, 1h05m).  task: the task id of the prompt, or role-message (only got its role).
#   --json     a JSON array of {role, title, handle, paneKey, state, since, sinceMs, task, tool, summary} instead of the lines
#   --run <id> also looks for dispatches whose text was never submitted (one worker-list; for a role in state done with a dispatch still open
#              whose task its prompt never named, one terminal show)
# Exit 0 whatever the states; 2 when the folder has no team, or Orca does not answer or does not know the folder.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
JSON=0; RUN=""; DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1;;
    --run) [ $# -ge 2 ] || { echo "team-status: --run needs a run id" >&2; exit 2; }; RUN="$2"; shift;;
    -*) echo "team-status: unknown option $1" >&2; exit 2;;
    *) [ -z "$DIR" ] || { echo "team-status: only one folder" >&2; exit 2; }; DIR="$1";;
  esac
  shift
done
DIR="${DIR:-.}"
TOP="$(cd "$DIR" 2>/dev/null && pwd -P)" || { echo "team-status: $DIR is not a folder" >&2; exit 2; }
GITDIR="$(git -C "$TOP" rev-parse --absolute-git-dir 2>/dev/null)" || GITDIR=""
[ -n "$GITDIR" ] && [ -s "$GITDIR/orca-roles.env" ] || { echo "team-status: $DIR has no orca-roles team" >&2; exit 2; }
CFG="$GITDIR/orca-roles.config.json"; [ -f "$CFG" ] || CFG=/dev/null
TOP="$(git -C "$TOP" rev-parse --show-toplevel 2>/dev/null || echo "$TOP")"; TOP="$(cd "$TOP" && pwd -P)"

PS="$(orca worktree ps --json 2>/dev/null)" && printf '%s' "$PS" | jq -e '.result.worktrees' >/dev/null 2>&1 || { echo "team-status: Orca did not answer 'worktree ps'" >&2; exit 2; }
ROW=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ "$p" = "$TOP" ] || [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$TOP" ]; then ROW="$p"; break; fi
done <<< "$(printf '%s' "$PS" | jq -r '.result.worktrees[].path')"
[ -n "$ROW" ] || { echo "team-status: Orca has no worktree at $TOP" >&2; exit 2; }
AGENTS="$(printf '%s' "$PS" | jq -c --arg p "$ROW" '[.result.worktrees[] | select(.path == $p) | .agents[]?]')"

NOW="${ORCA_ROLES_NOW_MS:-$(( $(date +%s) * 1000 ))}"   # the clock, in ms; the variable is for tests
ROLES="[]"
while IFS='=' read -r var handle; do
  [ -n "$var" ] || continue
  id="$(printf '%s' "$var" | tr 'A-Z_' 'a-z-')"
  tabs="$(grep "^$var=" "$GITDIR/orca-roles.tabs" 2>/dev/null | head -1 | cut -d= -f2-)"
  read -r tab leaf _ <<< "$tabs"
  pane=""; [ -z "$tab" ] || [ -z "$leaf" ] || pane="$tab:$leaf"
  ROLES="$(printf '%s' "$ROLES" | jq -c --arg r "$id" --arg t "$(title_of "$CFG" "$id" 2>/dev/null || echo "$id")" --arg h "$handle" --arg p "$pane" '. + [{role: $r, title: $t, handle: $h, paneKey: $p}]')"
done < "$GITDIR/orca-roles.env"

OUT="$(jq -n -c --argjson roles "$ROLES" --argjson agents "$AGENTS" --argjson now "$NOW" '
  def age($ms): if $ms == null then "-" elif $ms < 60000 then "\($ms / 1000 | floor)s"
    elif $ms < 3600000 then "\($ms / 60000 | floor)m"
    else "\($ms / 3600000 | floor)h\(($ms % 3600000) / 60000 | floor | tostring | if length < 2 then "0" + . else . end)m" end;
  def cut($s): if ($s | length) > 100 then ($s[0:100] + "…") else $s end;
  $roles | map(. as $r
    | ([$agents[] | select(.paneKey == $r.paneKey)] | sort_by(.updatedAt // 0) | last) as $a
    | ($a.prompt // "") as $pr
    | (if $r.paneKey == "" then "no-tab"
       elif $a == null then "no-status"
       elif $a.state == "working" then "working"
       elif $a.state == "waiting" or $a.state == "blocked" then "waiting"
       elif $a.state == "done" and $a.interrupted == true then "interrupted"
       elif $a.state == "done" and $a.outcome == "failure" then "failed"
       elif $a.state == "done" then "done"
       else $a.state end) as $st
    | (if $a == null or $a.stateStartedAt == null then null else ($now - $a.stateStartedAt | if . < 0 then 0 else . end) end) as $ms
    | $r + {state: $st, since: age($ms), sinceMs: $ms,
        task: (($pr | capture("(?<t>task_[0-9a-f]+)") | .t) // (if ($pr | test("^Read ")) and ($pr | test("(common-workers|planner)\\.md")) then "role-message" else "-" end)),
        tool: (if ($a.toolName // "") == "" then "-" else $a.toolName end),
        summary: (($a.lastAssistantMessage // "") | (split("\n")[0] // "") | gsub("\t"; " ") | if . == "" then "-" else cut(.) end),
        prompt: $pr})')"

if [ -n "$RUN" ]; then
  WL="$(orca orchestration worker-list --run "$RUN" --json 2>/dev/null)" || WL=""
  if [ -n "$WL" ]; then
    n="$(printf '%s' "$OUT" | jq 'length')"; i=0
    while [ "$i" -lt "$n" ]; do
      row="$(printf '%s' "$OUT" | jq -c ".[$i]")"; i=$((i + 1))
      [ "$(printf '%s' "$row" | jq -r .state)" = "done" ] || continue
      h="$(printf '%s' "$row" | jq -r .handle)"
      # a dispatch of this run to the role that is still open and whose task its prompt never named: the task text was not submitted
      printf '%s' "$WL" | jq -e --arg h "$h" --arg pr "$(printf '%s' "$row" | jq -r .prompt)" '[.result.workers[]? | select(.agentTerminalHandle == $h and (.dispatchStatus | IN("completed", "failed", "cancelled", "abandoned", "released") | not)) | select(. as $w | ($pr | contains($w.taskId)) | not)] | length > 0' >/dev/null 2>&1 || continue
      orca terminal show --terminal "$h" --json 2>/dev/null | jq -e '.result.terminal.preview // "" | contains("[Pasted text")' >/dev/null 2>&1 || continue
      OUT="$(printf '%s' "$OUT" | jq -c --argjson i "$((i - 1))" '.[$i].state = "undelivered"')"
    done
  fi
fi

if [ "$JSON" = 1 ]; then
  printf '%s' "$OUT" | jq 'map(del(.prompt))'
else
  printf '%s' "$OUT" | jq -r '.[] | [.title, .state, .since, .task, .tool, .summary] | join("\t")'
fi
