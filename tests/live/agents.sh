#!/usr/bin/env bash
# Live checks of the agents other than Claude Code (Codex, OpenCode): what the smoke tests cannot cover (see docs/live-checks.md).
# For whoever has those agents installed and signed in; Claude Code is not needed.
# Usage (from an Orca terminal of this checkout, with this checkout installed: ./install.sh):  tests/live/agents.sh
# One run, no restart. Report: ~/orca-live-checks/report-agents.md. To start over: rm ~/orca-live-checks/state-agents
set -uo pipefail
. "$(dirname "$0")/lib.sh"
PROJ="$LIVE_DIR/project-agents"
HAS_CODEX=0; command -v codex >/dev/null 2>&1 && HAS_CODEX=1
HAS_OC=0; command -v opencode >/dev/null 2>&1 && HAS_OC=1
[ "$HAS_CODEX$HAS_OC" != 00 ] || { echo "Neither codex nor opencode is installed: nothing to check." >&2; exit 1; }

agents_project() {  # a throwaway project whose team runs on the other agents: Planner and Dev on Codex, Tester on OpenCode
  if [ ! -d "$PROJ/.git" ]; then
    mkdir -p "$PROJ" && git -C "$PROJ" init -q -b main && echo "# agents live checks (throwaway)" > "$PROJ/README.md"
    jq -n --argjson cx "$HAS_CODEX" --argjson oc "$HAS_OC" '
      {settings: {jiraHandoff: false, cleanWorkersAfterStep: false, enableAskModeOnStart: false, superpowers: true},
       mcpServers: {"live-echo": {type: "stdio", command: "cat", args: []}},
       roles: ({researcher: {enabled: false}, auditor: {enabled: false}, "e2e-tester": {enabled: false}, deployer: {enabled: false}}
         + (if $cx == 1 then {planner: {agent: "codex", model: ""}, dev: {agent: "codex", model: "", mcp: ["live-echo"]}}
            else {dev: {enabled: false}} end)
         + (if $oc == 1 then {tester: {agent: "custom", command: "opencode", clearCommand: "/new", model: ""}}
            else {tester: {enabled: false}} end))}' > "$PROJ/.orca-roles.json"
    git -C "$PROJ" add -A && git -C "$PROJ" -c user.name=live -c user.email=live@localhost commit -qm "agents live checks project"
  fi
  (cd "$PROJ" && "$KIT/bin/orca-yaml.sh" --mode programmer >/dev/null 2>&1) || true
  orca repo add --path "$PROJ" --json >/dev/null 2>&1 || true
}
a_titles() {  # Codex and OpenCode keep the kit's tab title and Orca recognizes the agent (#43, BACKLOG)
  local id=$1 v h t a
  sleep 60   # long enough for an agent that retitles its tab to have done it
  for v in PLANNER DEV TESTER; do
    h="$(env_of $v)"; [ -n "$h" ] || continue
    t="$(orca terminal show --terminal "$h" --json 2>/dev/null | jfield result.terminal.title)"
    a="$(orca terminal show --terminal "$h" --json 2>/dev/null | jfield result.terminal.agentIdentity)"
    case "$t" in *"($(rstr_agent $v))") ok "$id.$v" "title kept: '$t'; Orca's agentIdentity: '${a:-none}'";;
      *) fail "$id.$v" "title changed to '$t' (expected the kit's '<Role> ($(rstr_agent $v))'); agentIdentity '${a:-none}'";; esac
  done
}
rstr_agent() { case "$1" in PLANNER|DEV) echo codex;; TESTER) echo opencode;; esac; }
a_codex_mcp() {  # Codex gets the role's MCP servers as -c overrides, without touching ~/.codex/config.toml (#1)
  local id=$1 h pid
  [ "$HAS_CODEX" = 1 ] || { skip "$id" "codex is not installed"; return; }
  h="$(env_of DEV)"; pid="$(pid_of_handle "$h")" || { fail "$id" "no Codex process for the Dev"; return; }
  ps -o args= -p "$pid" | grep -q 'mcp_servers.live-echo.command' && ok "$id.args" "the Dev's codex got mcp_servers.live-echo as a -c override" || fail "$id.args" "no live-echo override in the Dev's codex arguments"
  orca terminal send --terminal "$h" --text "/mcp" --enter --json >/dev/null 2>&1
  wait_screen "$h" 'live-echo' 20 && ok "$id.mcp" "codex /mcp lists live-echo" || fail "$id.mcp" "codex /mcp does not list live-echo"
  grep -q 'live-echo' "$HOME/.codex/config.toml" 2>/dev/null && fail "$id.config" "the codex config.toml was changed" || ok "$id.config" "the codex config.toml was not touched"
}
a_codex_new() {  # after /new Codex keeps its developer instructions: it still knows its role (#14)
  local id=$1 h
  [ "$HAS_CODEX" = 1 ] || { skip "$id" "codex is not installed"; return; }
  h="$(env_of DEV)"
  orca terminal wait --terminal "$h" --for tui-idle --timeout-ms 120000 --json >/dev/null 2>&1
  orca terminal send --terminal "$h" --text "/new" --enter --json >/dev/null 2>&1; sleep 5
  orca terminal send --terminal "$h" --text "Which role do you have in this team? Answer with the role name only." --enter --json >/dev/null 2>&1
  wait_screen "$h" '\bDev\b' 120 && ok "$id" "after /new the Dev still answers 'Dev'" || fail "$id" "after /new the Dev does not name its role: $(screen "$h" 5 | tr '\n' ' ')"
}
a_opencode_new() {  # OpenCode as a custom agent: its clear command keeps the role (the role anchor is resent by clean.sh)
  local id=$1 h out
  [ "$HAS_OC" = 1 ] || { skip "$id" "opencode is not installed"; return; }
  out="$(cd "$WT" && "$KIT/bin/clean.sh" tester 2>&1)"
  h="$(env_of TESTER)"
  wait_screen "$h" 'Tester' 120 && ok "$id" "clean.sh tester: /new then the role message ($out)" || fail "$id" "no role message on the Tester's screen after clean.sh: $out"
}
a_planner_superpowers() {  # superpowers is for Claude Planners only (#39): a Codex Planner starts without it and the launch says so
  local id=$1 h pid
  [ "$HAS_CODEX" = 1 ] || { skip "$id" "codex is not installed"; return; }
  h="$(env_of PLANNER)"; pid="$(pid_of_handle "$h")" || { fail "$id" "no Codex process for the Planner"; return; }
  ps -o args= -p "$pid" | grep -q superpowers && fail "$id" "the Codex Planner got superpowers arguments" || info "$id" "the Codex Planner runs without superpowers (claude only); launch log: $(grep -i superpowers "$GD/orca-roles-launch.log" | tail -1)"
}

live_start agents; live_preflight
agents_project
wt_load
if [ -z "$WT" ]; then
  wt_create "agents-$(date +%H%M%S)" || { fail A0 "orca worktree create failed"; exit 1; }
  for _ in $(seq 1 90); do [ -s "$GD/orca-roles.env" ] && [ -z "$(ls -A "$GD/orca-roles.kickoff.d" 2>/dev/null)" ] && break; sleep 2; done
  info A0 "team: $(tr '\n' ' ' < "$GD/orca-roles.env")"
  attach "A0 launch log" "$GD/orca-roles-launch.log"; attach "A0 kickoff log" "$GD/orca-roles-kickoff.log"
fi
run_check A1 a_titles
run_check A2 a_codex_mcp
run_check A3 a_codex_new
run_check A4 a_opencode_new
run_check A5 a_planner_superpowers
wt_cleanup; st_set phase finished
echo; echo "Finished. Send the report to the Planner: $REPORT"
