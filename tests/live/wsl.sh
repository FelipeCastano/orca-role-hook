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
c_close_own_tab() {  # the relauncher's hang (WSL bug report): a process started in a tab, detached with setsid, closing that same tab; then the kit's own bounded close
  local id=$1 orcabin a b f="$LIVE_DIR/close-own-tab.rc" fk="$LIVE_DIR/close-kit.result" sk="$LIVE_DIR/close-kit.sh" rc left js code gone="" listed="" terms res
  orcabin="$(command -v orca)"; rm -f "$f" "$fk"
  a="$(orca terminal create --worktree "id:$WTID" --title live-close-A --command bash --json 2>/dev/null < /dev/null | handle_of)"
  [ -n "$a" ] || { fail "$id" "could not open a test tab"; return; }
  sleep 3
  orca terminal send --terminal "$a" --text "setsid sh -c 'sleep 5; \"$orcabin\" terminal close --terminal $a --tab --json >/dev/null 2>&1 </dev/null; echo rc=\$? > \"$f\"' >/dev/null 2>&1 </dev/null &" --enter --json >/dev/null 2>&1 < /dev/null
  for _ in $(seq 1 60); do [ -s "$f" ] && break; sleep 1; done
  [ -s "$f" ] && sleep 2
  if terms="$(wt_terms 2>/dev/null)"; then listed="$(printf '%s\n' "$terms" | cut -f1 | grep -cx "$a")"; else listed=unknown; fi
  js="$(orca terminal show --terminal "$a" --json 2>/dev/null < /dev/null)"
  code="$(printf '%s' "$js" | jq -r '.error.code // empty' 2>/dev/null)"
  if [ "$listed" = 0 ] && { [ "$code" = terminal_handle_stale ] || printf '%s' "$js" | jq -e '[.. | objects | select(has("orphaned") and has("connected"))] | first | .orphaned == true and .connected == false' >/dev/null 2>&1; }; then gone=1; fi
  if [ -n "$gone" ]; then ok "$id.own" "the tab closed itself from a detached process"
  else fail "$id.own" "the tab is still open 60 s after it asked Orca to close it; terminal show: $(printf '%s' "$js" | tr '\n' ' ' | cut -c1-300)"; fi
  left="$(pgrep -af "terminal close --terminal $a" | head -2 | tr '\n' ' ')"
  if [ -s "$f" ]; then info "$id.answer" "Orca answered the close ($(cat "$f"))"
  else info "$id.answer" "Orca never answered the close in 60 s (Orca's WSL behaviour); left behind: ${left:-nothing}"
    pkill -f "terminal close --terminal $a" 2>/dev/null; fi
  b="$(orca terminal create --worktree "id:$WTID" --title live-close-kit --command bash --json 2>/dev/null < /dev/null | handle_of)"
  if [ -z "$b" ]; then fail "$id.kit" "could not open a test tab"
  else
    cat > "$sk" <<'EOS'
#!/usr/bin/env bash
# $1 tab handle, $2 result file, $3 the installed kit: closes the tab the way the kit does, then asks whether Orca confirmed it
. "$3/bin/lib.sh" >/dev/null 2>&1
sleep 5; t0=$SECONDS
orca terminal close --terminal "$1" --tab --json >/dev/null 2>&1 < /dev/null; c=$?
close_unconfirmed "$1" live-close-kit >/dev/null 2>&1 < /dev/null; u=$?
echo "close=$c confirm=$u secs=$((SECONDS - t0))" > "$2"
EOS
    sleep 3
    orca terminal send --terminal "$b" --text "setsid bash \"$sk\" $b \"$fk\" \"$KIT\" >/dev/null 2>&1 </dev/null &" --enter --json >/dev/null 2>&1 < /dev/null
    for _ in $(seq 1 45); do [ -s "$fk" ] && break; sleep 1; done
    res="$(cat "$fk" 2>/dev/null)"; left="$(pgrep -af "terminal close --terminal $b" | head -2 | tr '\n' ' ')"
    if [ -n "$res" ] && printf '%s' "$res" | grep -Eq '^close=(0|124) confirm=0 ' && [ -z "$left" ]; then ok "$id.kit" "the kit's bounded close of its own tab returns and counts the tab closed"
    else fail "$id.kit" "${res:-no result in 45 s}; left behind: ${left:-nothing}"; fi
    [ -z "$left" ] || pkill -f "terminal close --terminal $b" 2>/dev/null
  fi
  b="$(orca terminal create --worktree "id:$WTID" --title live-close-B --command bash --json 2>/dev/null < /dev/null | handle_of)"
  sleep 3; timeout 60 orca terminal close --terminal "$b" --tab --json >/dev/null 2>&1 < /dev/null; rc=$?
  check "$id.other" "closing another tab from this terminal returns" "$rc" 0
}
c_capacity() {  # the capacity measure in this WSL VM: the OS kind, the available memory, the pairs it fits, what it cannot measure
  local id=$1 j
  j="$(bash "$HOME/.orca-roles/bin/capacity.sh" --json 2>/dev/null)" || j=""
  printf '%s' "$j" | jq -e . >/dev/null 2>&1 || j="{}"
  info "$id" "os=$(printf '%s' "$j" | jq -r '.os // "none"'), availableMB=$(printf '%s' "$j" | jq -r '.availableMB // "null"'), pairs=$(printf '%s' "$j" | jq -c '.pairs' 2>/dev/null), notMeasured=$(printf '%s' "$j" | jq -c '.notMeasured' 2>/dev/null), os is wsl: $(printf '%s' "$j" | jq -r '.os == "wsl"' 2>/dev/null)"
}
c_cli_route_and_capacity() { run_check W0 c_cli_route; run_check W2 c_capacity; }
# shellcheck disable=SC2034  # read by live_main in lib.sh
EXTRA_BEFORE=c_cli_route_and_capacity
# shellcheck disable=SC2034  # read by live_main in lib.sh
EXTRA_TEAM=c_close_own_tab_once
c_close_own_tab_once() { run_check W1 c_close_own_tab; }
live_main wsl
