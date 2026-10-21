#!/usr/bin/env bash
# Starts the coordinator above the worktrees in this terminal: Claude Code with prompts/coordinator.md as its role. It opens worktrees
# (each one starts its orca-roles team), gives each Planner its feature as an Orca dispatch and talks to the user (see README, Coordinator).
# Usage (in an Orca terminal, e.g. in a project's main checkout):  coordinator.sh [--model <model>]
# Model and permission mode: --model, else the Planner's in the configuration. Trusts this folder for Claude Code as launch.sh does.
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
# Same trust as the teams (settings.trust, default "worktree"): with "never" Claude asks, as the user is in this tab anyway.
[ "$(trust_of "$CFG")" = worktree ] && trust_folder
rm -f "$CFG"
ARGS=(); [ -n "$MODEL" ] && ARGS+=(--model "$MODEL"); [ -n "$PERM" ] && ARGS+=(--permission-mode "$PERM")
# The message goes first: --add-dir takes several values and would swallow it as one more folder.
exec claude "Read $KIT/prompts/coordinator.md and adopt that role from now on. Start with \"When you start\"." ${ARGS[@]+"${ARGS[@]}"} --add-dir "$KIT/prompts"
