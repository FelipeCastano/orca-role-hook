#!/usr/bin/env bash
# Launches a role's agent according to the configuration.  Usage: agent.sh <role> [--resume <claude session id>]
# --resume: reopen the role's previous Claude Code conversation (launch.sh uses it for a tab Orca restored after a restart).
set -euo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
ROLE="$1"; shift; RESUME=""
while [ $# -gt 0 ]; do case "$1" in --resume) RESUME="${2:-}"; shift;; esac; shift; done
CFG="${ORCA_ROLES_CONFIG:-}"
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then CFG="$(mktemp)"; merged_config . > "$CFG"; fi

AGENT="$(rstr "$CFG" "$ROLE" agent)"; AGENT="${AGENT:-claude}"
MODEL="$(rstr "$CFG" "$ROLE" model)"
NICE="$(rstr "$CFG" "$ROLE" nice)"   # CPU priority of the agent and everything it runs (nice -n): the Tester and the Auditor run lowered
RUN=(); if [ -n "$NICE" ] && [ "$NICE" != 0 ] && command -v nice >/dev/null; then RUN=(nice -n "$NICE"); fi
[ -n "$RESUME" ] && [ "$AGENT" != claude ] && echo "agent.sh: --resume only applies to claude; $ROLE ($AGENT) starts fresh." >&2
PERM="$(rstr "$CFG" "$ROLE" permissionMode)"
PROMPT="$(prompt_of "$CFG" "$ROLE")"

# The role's environment variables (defaults.env + roles.<role>.env)
while IFS=$'\t' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < <(jq -r --arg r "$ROLE" '((.defaults.env // {}) * (.roles[$r].env // {})) | to_entries[] | "\(.key)\t\(.value)"' "$CFG")

# The role's MCP servers, in a file in mcpServers format. With mcp="all" none is generated: the agent uses its own configuration.
MCPFILE=""
if [ "$(rcfg "$CFG" "$ROLE" mcp)" != '"all"' ]; then
  role_context "$CFG" "$ROLE" .          # placeholders {worktree}, {project}, {evidenceDir}, {browserState}...
  ensure_browser_state "$ORCA_ROLES_BROWSER_STATE"
  # In the worktree's git dir, one per role, rewritten on every start (outside a repo, a temporary file)
  if GD="$(git rev-parse --git-dir 2>/dev/null)"; then MCPFILE="$(cd "$GD" && pwd)/orca-roles-mcp-$ROLE.json"; else MCPFILE="$(mktemp)"; fi
  mcp_file "$CFG" "$ROLE" > "$MCPFILE"
  export ORCA_ROLES_MCP="$MCPFILE"
fi

ARGS=()
add_list() {  # $1 field (array), $2 optional flag per element, $3 = path to expand ~, {kit} and {home}
  while IFS= read -r x; do [ -n "$x" ] || continue; [ "${3:-}" = path ] && x="$(expand_path "$x")"
    if [ -n "${2:-}" ]; then ARGS+=("$2" "$x"); else ARGS+=("$x"); fi
  done < <(rcfg "$CFG" "$ROLE" "$1" | jq -r '.[]?' 2>/dev/null)
}

case "$AGENT" in
  claude)
    [ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
    [ -n "$PERM" ] && [ "$PERM" != default ] && ARGS+=(--permission-mode "$PERM")
    ARGS+=(--add-dir "$KIT/prompts")
    SD="$(scratch_dir "$ROLE")" && mkdir -p "$SD" && ARGS+=(--add-dir "$SD")   # the role's scratch folder, outside the worktree
    PDIR="$(dirname "$PROMPT")"
    [ "$PDIR" != "$KIT/prompts" ] && [ -d "$PDIR" ] && ARGS+=(--add-dir "$PDIR")
    add_list extraDirs --add-dir path
    add_list pluginDirs --plugin-dir path   # Claude Code plugins for this role only (the Planner's skill)
    ARGS+=(--append-system-prompt "$(role_anchor "$CFG" "$ROLE")")   # survives /clear, unlike the role message
    if [ -n "$MCPFILE" ]; then
      ARGS+=(--strict-mcp-config --mcp-config "$MCPFILE")
      export ENABLE_CLAUDEAI_MCP_SERVERS=false
    fi
    TOOLS=(); while IFS= read -r t; do [ -n "$t" ] && TOOLS+=("$t"); done < <(rcfg "$CFG" "$ROLE" allowedTools | jq -r '.[]?')
    [ ${#TOOLS[@]} -gt 0 ] && ARGS+=(--allowedTools "${TOOLS[@]}")
    add_list extraArgs
    [ -n "$RESUME" ] && ARGS+=(--resume "$RESUME")
    exec "${RUN[@]+"${RUN[@]}"}" claude "${ARGS[@]}"
    ;;
  codex)
    [ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
    # auto = what --full-auto was (codex >= 0.126 rejects it): writes inside the worktree and the --add-dir folders, asks for the rest
    [ "$PERM" = auto ] && ARGS+=(--sandbox workspace-write --ask-for-approval on-request)
    # --add-dir only has an effect with workspace-write; the role's scratch folder is outside the worktree
    SD="$(scratch_dir "$ROLE")" && mkdir -p "$SD" && ARGS+=(--add-dir "$SD")
    add_list extraDirs --add-dir path
    # Trust answered with a configuration override instead of the "Do you trust this folder?" dialog; nothing is written.
    # It must be one inline table: the dotted form (projects."<path>".trust_level) is not read.
    ARGS+=(-c "$(jq -nr --arg p "$(pwd -P)" '"projects={\($p | @json) = {trust_level = \"trusted\"}}"')")
    # MCP servers as configuration overrides (-c mcp_servers.<name>.<field>=...), without touching ~/.codex/config.toml
    if [ -n "$MCPFILE" ]; then while IFS= read -r o; do [ -n "$o" ] && ARGS+=(-c "$o"); done < <(codex_mcp_overrides "$MCPFILE"); fi
    # The same anchor as claude's, as developer instructions, which /new keeps (they replace those of ~/.codex/config.toml)
    ARGS+=(-c "developer_instructions=$(role_anchor "$CFG" "$ROLE" | jq -Rs .)")
    add_list extraArgs
    exec "${RUN[@]+"${RUN[@]}"}" codex ${ARGS[@]+"${ARGS[@]}"}   # safe form for an empty list in bash 3.2 (macOS)
    ;;
  custom)
    # The command runs in a login shell (your profile's PATH). Placeholders:
    #   {model} → model field;  {prompts} → the kit's prompts folder;  {prompt} → the role's prompt file
    #   {mcp}   → {"mcpServers": {...}} file with the role's servers (empty if mcp="all"); also in $ORCA_ROLES_MCP
    #   {scratch} → the role's scratch folder (created before); also in $ORCA_ROLES_SCRATCH
    #   {anchor}  → the line that tells the agent to ask for its role again after its conversation is cleared, for the agent's
    #               system prompt flag if it has one (claude and codex get it on their own); also in $ORCA_ROLES_ANCHOR
    # extraArgs are appended. If the role has addDirFlag (e.g. "--add-dir"), "<flag> <scratch>" and "<flag> <dir>" for each of
    # its extraDirs are appended too. permissionMode and allowedTools do not apply (they are claude's), nor does extraDirs without addDirFlag.
    CMD="$(rstr "$CFG" "$ROLE" command)"
    [ -n "$CMD" ] || { echo "Role $ROLE is 'custom' but has no 'command'." >&2; exit 1; }
    SD="$(scratch_dir "$ROLE")" && mkdir -p "$SD" && export ORCA_ROLES_SCRATCH="$SD"
    Q_MODEL="$(printf '%q' "$MODEL")"; Q_PROMPTS="$(printf '%q' "$KIT/prompts")"; Q_PROMPT="$(printf '%q' "$PROMPT")"
    Q_MCP=""; [ -n "$MCPFILE" ] && Q_MCP="$(printf '%q' "$MCPFILE")"
    Q_SCRATCH=""; [ -n "${SD:-}" ] && Q_SCRATCH="$(printf '%q' "$SD")"
    export ORCA_ROLES_ANCHOR="$(role_anchor "$CFG" "$ROLE")"; Q_ANCHOR="$(printf '%q' "$ORCA_ROLES_ANCHOR")"
    CMD="${CMD//\{model\}/$Q_MODEL}"; CMD="${CMD//\{prompts\}/$Q_PROMPTS}"; CMD="${CMD//\{prompt\}/$Q_PROMPT}"; CMD="${CMD//\{mcp\}/$Q_MCP}"; CMD="${CMD//\{scratch\}/$Q_SCRATCH}"
    CMD="${CMD//\{anchor\}/$Q_ANCHOR}"
    DIRFLAG="$(rstr "$CFG" "$ROLE" addDirFlag)"
    if [ -n "$DIRFLAG" ]; then
      [ -n "${SD:-}" ] && ARGS+=("$DIRFLAG" "$SD")
      add_list extraDirs "$DIRFLAG" path
    fi
    add_list extraArgs
    for a in "${ARGS[@]+"${ARGS[@]}"}"; do CMD="$CMD $(printf '%q' "$a")"; done
    exec "${RUN[@]+"${RUN[@]}"}" bash -lc "$CMD"
    ;;
  *) echo "Unknown agent for $ROLE: $AGENT (use claude, codex or custom)" >&2; exit 1;;
esac
