#!/usr/bin/env bash
# Live checks on Windows + WSL with Claude Code: what the smoke tests cannot cover (see docs/live-checks.md).
# Usage (from any terminal, with Orca open and this checkout installed: ./install.sh):  tests/live/wsl.sh
# Run it once; it ends asking for a real restart of Orca. Run the same command again after the restart to finish.
# Report: ~/orca-live-checks/report-wsl.md. To start over: rm ~/orca-live-checks/state-wsl
set -uo pipefail
. "$(dirname "$0")/lib.sh"
live_is_wsl || { echo "This is not WSL: run tests/live/mac.sh on macOS." >&2; exit 1; }

c_cli_route() {  # how the orca CLI is reached from WSL (#19): the route the kit's shim uses
  local id=$1
  info "$id" "orca: $(command -v orca) -> $(head -c 300 "$(command -v orca)" 2>/dev/null | tr '\n' ' ' | cut -c1-200); ORCA_CLI_COMMAND=${ORCA_CLI_COMMAND:-unset}; version $(orca --version 2>/dev/null | head -1)"
}
c_close_own_tab() {  # the relauncher's hang (WSL bug report): a process started in a tab, detached with setsid, closing that same tab
  local id=$1 orcabin a b f="$LIVE_DIR/close-own-tab.rc" rc
  orcabin="$(command -v orca)"; rm -f "$f"
  a="$(orca terminal create --worktree "id:$WTID" --title live-close-A --command bash --json 2>/dev/null | handle_of)"
  [ -n "$a" ] || { fail "$id" "could not open a test tab"; return; }
  sleep 3
  orca terminal send --terminal "$a" --text "setsid sh -c 'sleep 5; \"$orcabin\" terminal close --terminal $a --tab --json >/dev/null 2>&1; echo rc=\$? > \"$f\"' >/dev/null 2>&1 &" --enter --json >/dev/null 2>&1
  for _ in $(seq 1 60); do [ -s "$f" ] && break; sleep 1; done
  if [ -s "$f" ]; then ok "$id.own" "closing its own tab from a setsid process returned ($(cat "$f")): the hypothesis does not hold"
  else fail "$id.own" "closing its own tab from a setsid process never returned in 60 s (the relauncher hang reproduces); lingering: $(pgrep -af "terminal close --terminal $a" | head -2 | tr '\n' ' ')"
    pkill -f "terminal close --terminal $a" 2>/dev/null; fi
  b="$(orca terminal create --worktree "id:$WTID" --title live-close-B --command bash --json 2>/dev/null | handle_of)"
  sleep 3; timeout 60 orca terminal close --terminal "$b" --tab --json >/dev/null 2>&1; rc=$?
  check "$id.other" "closing another tab from this terminal returns" "$rc" 0
}
# shellcheck disable=SC2034  # read by live_main in lib.sh
EXTRA_BEFORE=c_cli_route_once
c_cli_route_once() { run_check W0 c_cli_route; }
# shellcheck disable=SC2034  # read by live_main in lib.sh
EXTRA_TEAM=c_close_own_tab_once
c_close_own_tab_once() { run_check W1 c_close_own_tab; }
live_main wsl
