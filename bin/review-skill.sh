#!/usr/bin/env bash
# Finds and installs the review skill the pr-reviewer mode reads (settings.prReviewer: marketplace, plugin, skill).
# Usage: review-skill.sh status | path | root | install
#   status   installed <version> <installPath> (exit 0) | disabled <version> <installPath> (3) | missing (2) | error <reason> (1)
#   path     the absolute path of the skill file when the plugin is installed and enabled (0); otherwise the status line on stderr
#            and its exit code, or "skill file not found: <path>" (4)
#   root     the parent directory of the plugin's installPath, the version-independent folder holding every installed version, when
#            the plugin is installed and enabled (0); otherwise the same output and exit codes as path for the not-installed cases
#   install  adds the marketplace and installs the plugin with the claude CLI, then prints the path. It never asks anything and
#            only runs when called: whoever calls it asks the user first. If the plugin is already installed it only prints the
#            path; if it is disabled it refuses (3), because claude plugin install would re-enable it.
# Every claude call is cut after 60 seconds. Nothing is written in the worktree.
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
case "${1:-}" in -h|--help) sed -n 2,12p "$0"; exit 0;; esac
CMD="${1:-}"; [ $# -le 1 ] || { echo "review-skill.sh: one command at a time" >&2; exit 1; }
case "$CMD" in status|path|root|install) ;; *) sed -n 3,3p "$0" >&2; exit 1;; esac
cleanup() { local c; trap '' INT TERM; for c in $(pgrep -P $$ 2>/dev/null); do kill_tree "$c"; done; rm -rf "$T"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/orca-review-skill.XXXXXX")"; trap cleanup EXIT; trap 'exit 130' INT TERM
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$CFG" ] || { CFG="$T/config.json"; merged_config . > "$CFG"; }
pr() { jq -r --arg k "$1" '.settings.prReviewer[$k] // empty' "$CFG" 2>/dev/null; }
MARKET="$(pr marketplace)"; PLUGIN="$(pr plugin)"; SKILL="$(pr skill)"
if [ -z "$MARKET" ] || [ -z "$PLUGIN" ] || [ -z "$SKILL" ]; then
  MARKET="$(jq -r '.settings.prReviewer.marketplace // empty' "$KIT/config.default.json")"; PLUGIN="$(jq -r '.settings.prReviewer.plugin // empty' "$KIT/config.default.json")"
  SKILL="$(jq -r '.settings.prReviewer.skill // empty' "$KIT/config.default.json")"
fi
[ -n "$MARKET" ] && [ -n "$PLUGIN" ] && [ -n "$SKILL" ] || { echo "error settings.prReviewer must be {marketplace, plugin, skill}" >&2; exit 1; }
TO="${ORCA_ROLES_SKILL_TIMEOUT:-60}"
first_line() { head -1 | tr '\t\r' '  '; }
# <name> <command...>: runs it in the background with stdout/err in $T/<name>.out/.err, kills it after $TO seconds. Sets RC and TIMED.
bounded() {
  local i="$1" pid sl; shift
  "$@" > "$T/$i.out" 2> "$T/$i.err" < /dev/null & pid=$!
  ( trap 'kill ${sp:-} 2>/dev/null; exit 0' TERM; sleep "$TO" & sp=$!; wait $sp; : > "$T/$i.to"; kill_tree $pid ) > /dev/null 2>&1 & sl=$!
  wait $pid 2>/dev/null; RC=$?
  kill $sl 2>/dev/null; wait $sl 2>/dev/null
  TIMED=0; [ -f "$T/$i.to" ] && TIMED=1
  return 0
}
# Sets ST (installed|disabled|missing|error), STLINE (the status line) and STRC (its exit code). INSTALLPATH when installed.
status() {
  local row
  INSTALLPATH=""; STRC=1; ST=error
  command -v claude >/dev/null 2>&1 || { STLINE="error claude not found"; return 0; }
  bounded list claude plugin list --json
  if [ "$TIMED" = 1 ]; then STLINE="error claude timed out"; return 0; fi
  if [ "$RC" != 0 ]; then
    row="$(first_line < "$T/list.err")"; [ -n "$row" ] || row="$(first_line < "$T/list.out")"; [ -n "$row" ] || row="claude plugin list exited $RC"
    STLINE="error $row"; return 0
  fi
  jq -e 'type == "array"' "$T/list.out" >/dev/null 2>&1 || { STLINE="error claude plugin list did not print a JSON list"; return 0; }
  row="$(jq -r --arg p "$PLUGIN" '[.[] | objects | select(.id == $p and (.installPath | type) == "string" and .installPath != "")]
    | (map(select(.enabled == true)) | first) as $e | if $e then "installed\t\($e.version // "unknown")\t\($e.installPath)"
      elif length > 0 then "disabled\t\(.[0].version // "unknown")\t\(.[0].installPath)" else empty end' "$T/list.out" 2>/dev/null)"
  if [ -z "$row" ]; then ST=missing; STLINE=missing; STRC=2; return 0; fi
  ST="${row%%	*}"; INSTALLPATH="${row##*	}"; row="${row#*	}"; STLINE="$ST ${row%%	*} $INSTALLPATH"
  if [ "$ST" = installed ]; then STRC=0; else STRC=3; fi
}
show_path() {  # after status: prints the skill path, or the failure and sets the exit code
  local f
  if [ "$ST" != installed ]; then echo "$STLINE" >&2; return "$STRC"; fi
  f="${INSTALLPATH%/}/$SKILL"
  [ -f "$f" ] || { echo "skill file not found: $f" >&2; return 4; }
  printf '%s\n' "$f"
}
# <name> <command...>: runs a claude command; on failure prints its output and exits 1
must() {
  local n="$1"; shift
  bounded "$n" "$@"
  if [ "$TIMED" = 1 ]; then echo "error claude timed out" >&2; exit 1; fi
  [ "$RC" = 0 ] && return 0
  cat "$T/$n.out" "$T/$n.err" >&2; [ -s "$T/$n.out" ] || [ -s "$T/$n.err" ] || echo "claude $* exited $RC" >&2
  return 1
}

status
case "$CMD" in
  status) if [ "$ST" = error ]; then echo "$STLINE" >&2; else echo "$STLINE"; fi; exit "$STRC";;
  path) show_path; exit $?;;
  root) if [ "$ST" = installed ]; then dirname "${INSTALLPATH%/}"; exit 0; fi; show_path; exit $?;;
  install)
    if [ "$ST" = installed ]; then echo "already installed"; show_path; exit $?; fi
    if [ "$ST" = error ]; then echo "$STLINE" >&2; exit 1; fi
    if [ "$ST" = disabled ]; then echo "$STLINE" >&2; echo "the plugin is disabled: enable it with claude plugin enable $PLUGIN (install would re-enable it)" >&2; exit 3; fi
    bounded market claude plugin marketplace add "$MARKET"
    if [ "$TIMED" = 1 ]; then echo "error claude timed out" >&2; exit 1; fi
    if [ "$RC" != 0 ] && ! cat "$T/market.out" "$T/market.err" | grep -qi 'already exists'; then
      cat "$T/market.out" "$T/market.err" >&2; [ -s "$T/market.out" ] || [ -s "$T/market.err" ] || echo "claude plugin marketplace add exited $RC" >&2
      exit 1
    fi
    must install claude plugin install "$PLUGIN" || exit 1
    status; show_path; exit $?;;
esac
