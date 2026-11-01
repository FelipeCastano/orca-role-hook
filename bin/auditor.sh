#!/usr/bin/env bash
# Starts the on-demand Auditor in this terminal: Claude Code with prompts/auditor.md as its role. It audits the kit's roles and their metrics across
# worktrees and reports problems and improvement proposals; it changes nothing. Never started by a team: the global coordinator opens it when the user asks, or the user runs it.
# Usage (in an Orca terminal, e.g. the global coordinator's folder):  auditor [--model <model>]   (or ~/.orca-roles/bin/auditor.sh)
# Model and permission mode: --model, else roles.planner's in the configuration. Trusts this folder for Claude Code as coordinator.sh does. Scratch folder: $KIT/tmp/auditor.
set -euo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n 2,5p "$0"; exit 0;;
    --model) [ -n "${2:-}" ] || { echo "auditor.sh: --model needs a value" >&2; exit 1; }; MODEL="$2"; shift;;
    *) echo "auditor.sh: unknown option $1" >&2; exit 1;;
  esac
  shift
done
command -v claude >/dev/null || { echo "auditor.sh: 'claude' is not on the PATH" >&2; exit 1; }
CFG="$(mktemp)"; merged_config . > "$CFG"
[ -n "$MODEL" ] || MODEL="$(rstr "$CFG" planner model)"
PERM="$(rstr "$CFG" planner permissionMode)"
trust_launch_folder "$CFG"
rm -f "$CFG"
SCR="$KIT/tmp/auditor"; mkdir -p "$SCR"
# Agent/Task (reviewer_deny) and the kit's own files (kit_deny_rules): the Auditor proposes prompt changes, it never makes them.
DENY=(); while IFS= read -r t; do DENY+=("$t"); done < <(reviewer_deny; kit_deny_rules)
ARGS=(); [ -n "$MODEL" ] && ARGS+=(--model "$MODEL"); [ -n "$PERM" ] && ARGS+=(--permission-mode "$PERM")
# The message goes first: the variadic flags would swallow it.
exec claude "Read $KIT/prompts/auditor.md and adopt that role from now on. Configuration parameters: scratchDir=$SCR." ${ARGS[@]+"${ARGS[@]}"} --disallowedTools "${DENY[@]}" --add-dir "$KIT"
