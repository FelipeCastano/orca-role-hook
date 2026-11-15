#!/usr/bin/env bash
# Starts the coordinator above the worktrees in this terminal: Claude Code with prompts/coordinator.md as its role. It opens worktrees
# (each one starts its orca-roles team), gives each local coordinator its feature as an Orca dispatch and talks to the user (see README, Coordinator).
# Usage (in an Orca terminal, e.g. in a project's main checkout):  coordinator.sh [--model <model>]
# Model, permission mode and advisor: --model, else roles.planner's in the configuration (the coordinator is a strong-model role, like the Planner). Trusts this folder for Claude Code as launch.sh does. Reads Orca's nested worker depth (lib.sh orca_nested_depth) and tells the coordinator.
set -euo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n 2,5p "$0"; exit 0;;
    --model) [ -n "${2:-}" ] || { echo "coordinator.sh: --model needs a value" >&2; exit 1; }; MODEL="$2"; shift;;
    *) echo "coordinator.sh: unknown option $1" >&2; exit 1;;
  esac
  shift
done
command -v claude >/dev/null || { echo "coordinator.sh: 'claude' is not on the PATH" >&2; exit 1; }
CFG="$(mktemp)"; merged_config . > "$CFG"
[ -n "$MODEL" ] || MODEL="$(rstr "$CFG" planner model)"
PERM="$(rstr "$CFG" planner permissionMode)"
ADVOK=1; ADVISOR="$(advisor_of "$CFG" planner)" || ADVOK=0
trust_launch_folder "$CFG"
rm -f "$CFG"
DEPTH="$(orca_nested_depth)"
if [ -n "$DEPTH" ] && [ "$DEPTH" -lt 2 ]; then
  echo "coordinator.sh: Orca's Nested worker depth is $DEPTH; each local coordinator needs 2 (global coordinator -> local coordinator -> Planner and workers: depth 2) (Settings → Orchestration → \"Nested worker depth\")."
fi
if session_hook_enabled; then ensure_session_hook_or_warn; fi   # the SessionStart hook that re-binds a reopened tab's Runs
ARGS=(); [ -n "$MODEL" ] && ARGS+=(--model "$MODEL"); [ -n "$PERM" ] && ARGS+=(--permission-mode "$PERM")
# The Planner's advisor: a model adds Claude Code's hidden --advisor, off disables the tool, auto adds nothing
ADV_ARGS=()
if [ "$ADVOK" = 0 ]; then
  echo "coordinator.sh: the advisor setting of planner is not valid (see README, \"Advisor of a role\"); the coordinator starts without the kit's advisor setting." >&2
elif [ "$ADVISOR" = off ]; then
  export CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1
elif [ "$ADVISOR" != auto ]; then
  AV="$(cli_version claude)"
  if advisor_cli_ok "$AV"; then
    ADV_ARGS+=(--advisor "$ADVISOR")
    unset CLAUDE_CODE_DISABLE_ADVISOR_TOOL   # no role env here: a value inherited from the calling shell must not switch the advisor off
  else
    CV=""; if [[ "$AV" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then CV="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"; fi
    echo "coordinator.sh: Claude Code $CV has no --advisor option (the kit's advisor setting needs 2.1.322 or later); the coordinator starts without it." >&2
  fi
fi
# The message goes first: --add-dir takes several values and would swallow it as one more folder.
if [ -n "$DEPTH" ]; then DEPTH_MSG=" Orca's nested worker depth is $DEPTH."; else DEPTH_MSG=" Orca's nested worker depth could not be read."; fi
MEM="$(claude_memory_settings '{}')"; MEM_ARGS=(); [ "$MEM" = '{}' ] || MEM_ARGS=(--settings "$MEM")
# Marks this Claude session as a global coordinator's: the SessionStart hook starts the reopen of the coordinated worktrees' teams when it comes back with a new handle.
export ORCA_ROLES_SESSION_KIND=coordinator
exec claude "Read $KIT/prompts/coordinator.md and adopt that role from now on. Start with \"When you start\".$DEPTH_MSG" ${ARGS[@]+"${ARGS[@]}"} "${MEM_ARGS[@]+"${MEM_ARGS[@]}"}" --add-dir "$KIT/prompts" "${ADV_ARGS[@]+"${ADV_ARGS[@]}"}"
