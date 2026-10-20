#!/usr/bin/env bash
# Token usage per role and session for this worktree, as JSON lines on stdout.  Read-only.
# Usage (from the worktree):  metrics.sh [--since <ISO date>] [--save]
#   --since  only turns at or after that timestamp/date (e.g. 2026-01-31 or 2026-01-31T09:00:00Z)
#   --save   also append the lines to <git dir>/orca-roles.runs.jsonl
# Claude: reads Claude Code's session files (${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<worktree path with / and . as ->/<session>.jsonl);
# the role of a session is found from the kit's role message in it ("unknown" if there is none). OpenCode: one line with its raw
# `stats` output, not split per role (it cannot be). Tokens only, no prices.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
SAVE=0; SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --save) SAVE=1;;
    --since) SINCE="${2:-}"; [ -n "$SINCE" ] || { echo "metrics.sh: --since needs a date" >&2; exit 1; }; shift;;
    -h|--help) sed -n 2,9p "$0"; exit 0;;
    *) echo "metrics.sh: unknown option $1" >&2; sed -n 3,5p "$0" >&2; exit 1;;
  esac
  shift
done
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "metrics.sh: run it from the worktree." >&2; exit 1; }
WT="$(cd "$TOP" && pwd -P)"
GITDIR="$(git rev-parse --git-dir)"; GITDIR="$(cd "$GITDIR" && pwd)"
OUTF="$(mktemp "${TMPDIR:-/tmp}/orca-roles-metrics.XXXXXX")"; trap 'rm -f "$OUTF" "$OUTF.o" "$OUTF.cfg"' EXIT

# Runs a command with a time limit (seconds), stdin closed, stdout in $OUTF.o.  limited <seconds> <command...>
limited() {
  local t="$1" pid; shift
  "$@" > "$OUTF.o" 2>/dev/null < /dev/null & pid=$!
  for _ in $(seq 1 $((t * 10))); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
  wait "$pid"
}

# --- Claude Code sessions
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
SDIR="$PROJECTS/$(printf '%s' "$WT" | tr '/.' '--')"
[ -d "$SDIR" ] || SDIR="$PROJECTS/$(printf '%s' "$WT" | tr -c 'A-Za-z0-9\n' '-')"   # newer Claude Code versions replace every non-alphanumeric
if [ -d "$SDIR" ]; then
  for f in "$SDIR"/*.jsonl; do
    [ -f "$f" ] || continue
    jq -cs --arg wt "$WT" --arg since "$SINCE" --arg file "$(basename "$f" .jsonl)" '
      def txt: (.message.content // "") | if type == "string" then . elif type == "array" then map(select(type == "object" and .type == "text") | .text) | join(" ") else "" end;
      def role_of: txt | (capture("Read (?<p>.*?) and adopt that role"; "s") | .p) // empty
        | [scan("[^/\\s]+\\.md")] | map(sub("\\.md$"; "")) | map(select(startswith("common-") | not)) | last // empty;
      [.[] | select(type == "object" and .cwd == $wt)] as $l
      | ([$l[] | select(.type == "user") | role_of] | first // "unknown") as $role
      | [$l[] | select(.type == "assistant" and (.message.usage | type) == "object" and ($since == "" or (.timestamp // "") >= $since))] as $t
      | select($t | length > 0)
      | {agent: "claude", role: $role, session: ($t[0].sessionId // $file),
         model: ([$t[] | .message.model // empty | select(. != "<synthetic>")] | last),
         version: ([$t[] | .version // empty] | last),
         first: ([$t[] | .timestamp // empty] | min), last: ([$t[] | .timestamp // empty] | max),
         turns: ($t | length),
         input: ([$t[] | .message.usage.input_tokens // 0] | add),
         output: ([$t[] | .message.usage.output_tokens // 0] | add),
         cacheRead: ([$t[] | .message.usage.cache_read_input_tokens // 0] | add),
         cacheWrite: ([$t[] | .message.usage.cache_creation_input_tokens // 0] | add)}' "$f" 2>/dev/null >> "$OUTF" \
      || echo "metrics.sh: warning: could not read $(basename "$f")" >&2
  done
fi

# --- OpenCode: only when the configuration runs it and the binary exists; its stats cannot be split per role
CFG="${ORCA_ROLES_CONFIG:-}"
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then
  CFG="$GITDIR/orca-roles.config.json"
  [ -f "$CFG" ] || { CFG="$OUTF.cfg"; merged_config . > "$CFG" 2>/dev/null || echo '{}' > "$CFG"; }
fi
uses_opencode() {
  local r a c
  for r in $(jq -r '.roles // {} | keys[]' "$CFG" 2>/dev/null); do
    a="$(rstr "$CFG" "$r" agent)"; c="$(rstr "$CFG" "$r" command)"; c="${c#"${c%%[![:space:]]*}"}"
    [ "$a" = opencode ] && return 0
    [ "$a" = custom ] && case "$c" in opencode|opencode\ *) return 0;; esac
  done
  return 1
}
if command -v opencode >/dev/null 2>&1 && uses_opencode; then
  if limited "${ORCA_ROLES_METRICS_TIMEOUT:-30}" opencode stats --json --cost --project . && jq -e . "$OUTF.o" >/dev/null 2>&1; then
    jq -nc --slurpfile raw "$OUTF.o" '{agent: "opencode", role: null, raw: $raw[0]}' >> "$OUTF"
  else
    echo "metrics.sh: warning: 'opencode stats' failed or timed out; no OpenCode line." >&2
  fi
fi

cat "$OUTF"
if [ "$SAVE" = 1 ] && [ -s "$OUTF" ]; then cat "$OUTF" >> "$GITDIR/orca-roles.runs.jsonl" || echo "metrics.sh: warning: could not write orca-roles.runs.jsonl" >&2; fi
exit 0
