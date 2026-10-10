#!/usr/bin/env bash
# Lists the models a role can use and, with --check, tests each one.  Usage: models.sh <role|title> [--check] [--model <m>]
# Without --check it prints the candidates, one per line, and spends nothing: claude's aliases (it cannot list the models of your
# login), codex's `codex debug models`, or the role's models.list command (custom). The role's own model comes first.
# With --check it runs one minimal probe per candidate, in parallel, and prints "<model><TAB>ok<TAB><resolved id>",
# "<model><TAB>unavailable" or "<model><TAB>unknown<TAB><reason>" (the probe could not tell: not logged in, offline, timed out...).
# A claude probe costs nothing for a model that does not exist and at most about 0.012 USD the first time for one that does.
# --model <m> replaces the candidates with exactly <m>, to test or print only that one.
# Nothing is written outside a temporary folder except the agents' own logs (Codex keeps its logs even for ephemeral runs), and no agent
# setting is changed. The role's env is exported to the list command and the probes. At most 6 probes run at a time.
set -uo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
case "${1:-}" in -h|--help) sed -n 2,10p "$0"; exit 0;; esac
ROLEARG=""; CHECK=0; ONLY=""
while [ $# -gt 0 ]; do a="$1"; case "$a" in --check) CHECK=1;; --model) [ -n "${2:-}" ] || { echo "models.sh: --model needs a value" >&2; exit 1; }; ONLY="$2"; shift;; -*) echo "models.sh: unknown option $a" >&2; exit 1;; *) [ -z "$ROLEARG" ] && ROLEARG="$a" || { echo "models.sh: only one role at a time" >&2; exit 1; };; esac; shift; done
[ -n "$ROLEARG" ] || { sed -n 2,2p "$0" >&2; exit 1; }
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill -9 "$1" 2>/dev/null; }
# On exit (also Ctrl+C or TERM) kill every process still running under this script, probes included, then remove the temp dir
cleanup() { local c; trap '' INT TERM; for c in $(pgrep -P $$ 2>/dev/null); do kill_tree "$c"; done; rm -rf "$T"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/orca-models.XXXXXX")"; trap cleanup EXIT; trap 'exit 130' INT TERM
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$CFG" ] || { CFG="$T/config.json"; merged_config . > "$CFG"; }

ROLE="$(resolve_role "$CFG" "$ROLEARG")"
[ -n "$ROLE" ] || { echo "Unknown role: $ROLEARG" >&2; exit 1; }
AGENT="$(rstr "$CFG" "$ROLE" agent)"; AGENT="${AGENT:-claude}"
MODEL="$(rstr "$CFG" "$ROLE" model)"
mopt() { jq -r --arg r "$ROLE" --arg k "$1" '(((.defaults.models // {}) * (.roles[$r].models // {}))[$k]) // empty' "$CFG" 2>/dev/null; }
while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}=${kv#*=}"; done < <(role_env "$CFG" "$ROLE")
first_line() { head -1 | tr '\t\r' '  '; }

TO="${ORCA_ROLES_PROBE_TIMEOUT:-90}"
PROBE="$(mopt probe)"
# <i> <command...>: runs the probe in the background with stdout/err in $T/<i>.out/.err, kills it after $TO seconds. Sets RC and TIMED.
bounded() {
  local i="$1" pid sl; shift
  "$@" > "$T/$i.out" 2> "$T/$i.err" < /dev/null & pid=$!
  ( trap 'kill ${sp:-} 2>/dev/null; exit 0' TERM; sleep "$TO" & sp=$!; wait $sp; : > "$T/$i.to"; kill_tree $pid ) > /dev/null 2>&1 & sl=$!
  wait $pid 2>/dev/null; RC=$?
  kill $sl 2>/dev/null; wait $sl 2>/dev/null
  TIMED=0; [ -f "$T/$i.to" ] && TIMED=1
  return 0
}
CANDS="$T/cands"; : > "$CANDS"
emit() { [ -z "$1" ] || printf '%s\n' "$1" >> "$CANDS"; }
case "$AGENT" in claude|codex|custom) ;; *) echo "Unknown agent for $ROLE: $AGENT (use claude, codex or custom)" >&2; exit 1;; esac
[ -n "$ONLY" ] || case "$AGENT" in
  claude)
    emit "$MODEL"; for m in sonnet opus haiku fable; do emit "$m"; done
    [ "$CHECK" = 1 ] || echo "Claude Code cannot list the models of your login; these are its aliases. Use --check to test them." >&2;;
  codex)
    emit "$MODEL"
    bounded dm codex debug models
    if [ "$TIMED" = 1 ]; then echo "codex debug models timed out after $TO s" >&2
    elif [ "$RC" = 0 ] && jq -e . "$T/dm.out" >/dev/null 2>&1; then
      while IFS= read -r m; do emit "$m"; done < <(jq -r '.models[]? | select(.visibility == "list") | .slug' "$T/dm.out")
    else
      echo "codex debug models failed: $(first_line < "$T/dm.err")" >&2
    fi;;
  custom)
    emit "$MODEL"
    LIST="$(mopt list)"; PARSE="$(mopt parse)"; PARSE="${PARSE:-lines}"
    if [ -z "$LIST" ]; then echo "$ROLE has no models.list in its configuration" >&2
    elif bounded list bash -c "$LIST"; [ "$TIMED" = 1 ]; then echo "models.list timed out after $TO s" >&2
    elif [ "$RC" != 0 ]; then echo "models.list failed: $(first_line < "$T/list.err")" >&2
    else
      case "$PARSE" in
        lines) while IFS= read -r l; do emit "$l"; done < <(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$T/list.out");;
        json:*) if jq -r "${PARSE#json:}" "$T/list.out" > "$T/parsed" 2> "$T/parse.err"; then while IFS= read -r l; do emit "$l"; done < "$T/parsed"
                else echo "models.parse failed: $(first_line < "$T/parse.err")" >&2; fi;;
        regex:*) re="${PARSE#regex:}"; while IFS= read -r l; do [[ $l =~ $re ]] && emit "${BASH_REMATCH[1]:-}"; done < "$T/list.out";;
        *) echo "models.parse must be lines, json:<jq filter> or regex:<ERE>" >&2;;
      esac
    fi;;
esac
[ -z "$ONLY" ] || printf '%s\n' "$ONLY" > "$CANDS"
awk '!seen[$0]++' "$CANDS" > "$CANDS.u"; mv "$CANDS.u" "$CANDS"
[ "$CHECK" = 1 ] || { cat "$CANDS"; exit 0; }

probe_claude() { claude -p --safe-mode --setting-sources local --no-session-persistence --tools "" --system-prompt "Reply ok." --model "$1" --output-format json ok; }
# Why a codex probe failed: the turn.failed error of its JSON events, else the last error event, else a line saying "unexpected status"
# (without the log prefix), else the first line that is not the stdin banner
codex_why() {
  local o="$T/$1.out" e="$T/$1.err" w
  w="$(jq -Rr 'fromjson? | select(type == "object" and .type == "turn.failed") | .error.message // empty' "$o" 2>/dev/null | tail -1)"
  [ -n "$w" ] || w="$(jq -Rr 'fromjson? | select(type == "object" and .type == "error") | .message // empty' "$o" 2>/dev/null | tail -1)"
  [ -n "$w" ] || w="$(cat "$e" "$o" | grep -m1 'unexpected status' | sed -E 's/^[0-9-]+T[0-9:.]+Z +[A-Z]+ +[^ ]+: //')"
  [ -n "$w" ] || w="$(cat "$e" "$o" | grep -v -e '^$' -e '^Reading additional input from stdin' | head -1)"
  printf '%s\n' "$w" | first_line
}
probe_codex() { codex exec --ephemeral --json --skip-git-repo-check -m "$1" "Reply ok."; }
probe_custom() { bash -c "${PROBE//\{model\}/$(printf '%q' "$1")}"; }
one() {  # <i> <model> → writes $T/<i>.res
  local i="$1" m="$2" why res
  mkdir -p "$T/wd.$i"; cd "$T/wd.$i" || return
  if [ "$AGENT" = custom ] && [ -z "$PROBE" ]; then printf '%s\tunknown\tno models.probe\n' "$m" > "$T/$i.res"; return; fi
  bounded "$i" "probe_$AGENT" "$m"
  if [ "$TIMED" = 1 ]; then res="unknown	timed out"
  else case "$AGENT" in
    claude)
      if [ "$RC" = 0 ]; then res="ok	$(jq -r '(.modelUsage // {}) | keys_unsorted | first // "-"' "$T/$i.out" 2>/dev/null || true)"; [ "$res" = "ok	" ] && res="ok	-"
      elif jq -e '(.api_error_status == 404) or (((.result // "") | tostring) | (startswith("There'"'"'s an issue with the selected model") or startswith("The model ")))' "$T/$i.out" >/dev/null 2>&1; then res="unavailable"
      else
        why="$(jq -r '.result // empty' "$T/$i.out" 2>/dev/null | first_line)"; [ -n "$why" ] || why="$(first_line < "$T/$i.err")"
        [ -n "$why" ] || why="$(first_line < "$T/$i.out")"; [ -n "$why" ] || why="exit $RC"
        res="unknown	${why:0:80}"
      fi;;
    codex)
      if [ "$RC" = 0 ]; then res="ok	-"
      elif cat "$T/$i.out" "$T/$i.err" | grep -qE 'does not exist|not supported|model_not_found'; then res="unavailable"
      else why="$(codex_why "$i")"; [ -n "$why" ] || why="exit $RC"; res="unknown	${why:0:80}"; fi;;
    custom) if [ "$RC" = 0 ]; then res="ok	-"; else res="unavailable"; fi;;
  esac; fi
  printf '%s\t%s\n' "$m" "$res" > "$T/$i.res"
}
n=0; PIDS=()
while IFS= read -r m; do
  if [ "${#PIDS[@]}" -ge 6 ]; then wait "${PIDS[0]}" 2>/dev/null; PIDS=("${PIDS[@]:1}"); fi
  n=$((n + 1)); one "$n" "$m" & PIDS+=($!)
done < "$CANDS"
wait
i=1; while [ "$i" -le "$n" ]; do cat "$T/$i.res" 2>/dev/null; i=$((i + 1)); done
exit 0
