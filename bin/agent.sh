#!/usr/bin/env bash
# Launches a role's agent according to the configuration.  Usage: agent.sh <role> [--resume <claude session id>]
# --resume: reopen the role's previous Claude Code conversation (launch.sh uses it for a tab Orca restored after a restart).
set -euo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
ROLE="$1"; shift; RESUME=""
while [ $# -gt 0 ]; do case "$1" in --resume) RESUME="${2:-}"; shift;; esac; shift; done
CFG="${ORCA_ROLES_CONFIG:-}"
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then CFG="$(mktemp)"; merged_config . > "$CFG"; fi

AGENT="$(rstr "$CFG" "$ROLE" agent)"; AGENT="${AGENT:-claude}"
MODEL="$(rstr "$CFG" "$ROLE" model)"
NICE="$(rstr "$CFG" "$ROLE" nice)"   # CPU priority of the agent and everything it runs (nice -n): the Tester and the Auditor run lowered
RUN=(); if [ -n "$NICE" ] && [ "$NICE" != 0 ] && command -v nice >/dev/null; then RUN=(nice -n "$NICE"); fi
[ -n "$RESUME" ] && [ "$AGENT" != claude ] && [ "$AGENT" != opencode ] && echo "agent.sh: --resume only applies to claude; $ROLE ($AGENT) starts fresh." >&2
PERM="$(rstr "$CFG" "$ROLE" permissionMode)"
PROMPT="$(prompt_of "$CFG" "$ROLE")"

# The role's environment variables (defaults.env + roles.<role>.env)
while IFS=$'\t' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < <(jq -r --arg r "$ROLE" '((.defaults.env // {}) * (.roles[$r].env // {})) | to_entries[] | "\(.key)\t\(.value)"' "$CFG")
# settings.telemetry.roleAttribute: the role as an OpenTelemetry attribute, added to the ones already set (shell or env above), never replacing them
if telemetry_role_attribute "$CFG"; then export OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES:+$OTEL_RESOURCE_ATTRIBUTES,}orca_roles.role=$ROLE"; fi

# The role's MCP servers, in a file in mcpServers format. With mcp="all" none is generated: the agent uses its own configuration.
MCPFILE=""
if [ "$AGENT" != opencode ] && [ "$(rcfg "$CFG" "$ROLE" mcp)" != '"all"' ]; then
  role_context "$CFG" "$ROLE" .          # placeholders {worktree}, {project}, {evidenceDir}, {browserState}...
  ensure_browser_state "$ORCA_ROLES_BROWSER_STATE"
  # In the worktree's git dir, one per role, rewritten on every start (outside a repo, a temporary file)
  if GD="$(git rev-parse --git-dir 2>/dev/null)"; then MCPFILE="$(cd "$GD" && pwd)/orca-roles-mcp-$ROLE.json"; else MCPFILE="$(mktemp)"; fi
  mcp_file "$CFG" "$ROLE" > "$MCPFILE"
  export ORCA_ROLES_MCP="$MCPFILE"
fi

# What this role is about to run, one JSON line in the worktree's git dir (outside a repo: nothing). Best-effort: it never stops the agent.
# cliVersion is the first line of `<binary> --version` (claude/codex), killed after ~3 s; null for a custom command.
record_provenance() {  # $1 binary to ask for its version, "" for none
  local gd ver="" out pid sha_c sha_p kv ki
  gd="$(git rev-parse --git-dir 2>/dev/null)" && gd="$(cd "$gd" && pwd)" || return 0
  if [ -n "$1" ] && command -v "$1" >/dev/null 2>&1; then
    out="$(mktemp)"; "$1" --version > "$out" 2>/dev/null < /dev/null & pid=$!
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; ver="$(head -1 "$out")"; rm -f "$out"
  fi
  sha_c="$(shasum "$CFG" 2>/dev/null | cut -d' ' -f1)"; sha_p=""; [ -f "$PROMPT" ] && sha_p="$(shasum "$PROMPT" 2>/dev/null | cut -d' ' -f1)"
  kv="$(head -1 "$KIT/VERSION" 2>/dev/null)"; ki="$(head -1 "$KIT/.installed" 2>/dev/null)"
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg role "$ROLE" --arg agent "$AGENT" --arg model "$MODEL" --arg cli "$ver" \
    --arg cfg "$sha_c" --arg pr "$sha_p" --arg kit "$kv" --arg inst "$ki" \
    '{ts:$ts, role:$role, agent:$agent, model:(if $model == "" then null else $model end), cliVersion:(if $cli == "" then null else $cli end),
      configSha:(if $cfg == "" then null else $cfg end), promptSha:(if $pr == "" then null else $pr end),
      kit:(if $kit == "" then null else $kit end), installed:(if $inst == "" then null else $inst end)}' >> "$gd/orca-roles.provenance.jsonl"
}

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
    case "$PDIR/" in "$KIT/prompts/"*) ;; *) [ -d "$PDIR" ] && ARGS+=(--add-dir "$PDIR");; esac
    add_list extraDirs --add-dir path
    # Claude Code plugins for this role only (the Planner's skill, superpowers); a folder that does not exist is skipped
    # settings.superpowers = false: the kit's superpowers folder is not loaded for any role (and so gets no kit deny list)
    SP_REAL=""; [ -d "$KIT/plugins/superpowers" ] && SP_REAL="$(cd "$KIT/plugins/superpowers" && pwd -P)"
    SP_OFF=0; [ "$(jq -r 'if .settings.superpowers == false then "off" else "on" end' "$CFG")" = off ] && SP_OFF=1
    LOADED_PLUGINS=()
    while IFS= read -r x; do
      [ -n "$x" ] || continue; x="$(expand_path "$x")"
      if [ "$SP_OFF" = 1 ] && { [ "${x%/}" = "$KIT/plugins/superpowers" ] || { [ -n "$SP_REAL" ] && [ -d "$x" ] && [ "$(cd "$x" && pwd -P)" = "$SP_REAL" ]; }; }; then continue; fi
      if [ -d "$x" ]; then ARGS+=(--plugin-dir "$x"); LOADED_PLUGINS+=("$x"); else echo "agent.sh: plugin folder $x not found; skipped." >&2; fi
    done < <(rcfg "$CFG" "$ROLE" pluginDirs | jq -r '.[]?' 2>/dev/null)
    ARGS+=(--append-system-prompt "$(role_anchor "$CFG" "$ROLE")")   # survives /clear, unlike the role message
    if [ -n "$MCPFILE" ]; then
      ARGS+=(--strict-mcp-config --mcp-config "$MCPFILE")
      export ENABLE_CLAUDEAI_MCP_SERVERS=false
    fi
    TOOLS=(); while IFS= read -r t; do [ -n "$t" ] && TOOLS+=("$t"); done < <(rcfg "$CFG" "$ROLE" allowedTools | jq -r '.[]?')
    [ ${#TOOLS[@]} -gt 0 ] && ARGS+=(--allowedTools "${TOOLS[@]}")
    # Workers cannot rewrite the kit through the --add-dir above (deny rules win over every permission mode). The Planner can: it
    # edits the configuration for the user. As --disallowedTools, not in --settings, which a role's own --settings would replace.
    if [ "$ROLE" != planner ]; then
      DENY=(); while IFS= read -r r; do DENY+=("$r"); done < <(kit_deny_rules)
      ARGS+=(--disallowedTools "${DENY[@]}")
    fi
    # The kit's deny list for superpowers: first, and not removable by the role's own list. The Planner always gets it (its entries are inert
    # without the plugin, and a superpowers the user installed may load); any other role gets it when it loads the kit's superpowers folder
    # (compared by physical path: a trailing slash, a '..' or a symlink to the folder match too)
    DENY_KIT=0; [ "$ROLE" != planner ] || DENY_KIT=1
    for x in ${LOADED_PLUGINS[@]+"${LOADED_PLUGINS[@]}"}; do
      if [ -n "$SP_REAL" ] && [ "$(cd "$x" && pwd -P)" = "$SP_REAL" ]; then DENY_KIT=1; break; fi
    done
    if [ "$DENY_KIT" = 1 ]; then
      DENY=(); while IFS= read -r t; do DENY+=("$t"); done < <(superpowers_deny)
      ARGS+=(--disallowedTools "${DENY[@]}")
    fi
    # Nobody answers a dialog in a worker's tab (the Planner is the only one that talks to the user): workers cannot open one. In permissionMode
    # plan the plan tools stay, they are how that mode works. A --disallowedTools in extraArgs adds to this list.
    if [ "$ROLE" != planner ]; then
      if [ "$PERM" = plan ]; then ARGS+=(--disallowedTools AskUserQuestion)
      else ARGS+=(--disallowedTools AskUserQuestion EnterPlanMode ExitPlanMode); fi
    fi
    # The role's own disallowedTools: it only adds to the lists above, it never removes the kit's
    OWN=(); while IFS= read -r t; do [ -n "$t" ] && OWN+=("$t"); done < <(rcfg "$CFG" "$ROLE" disallowedTools | jq -r '.[]?')
    [ ${#OWN[@]} -gt 0 ] && ARGS+=(--disallowedTools "${OWN[@]}")
    # Claude Code's own `language` setting (user settings) outranks the prompt: workers override it to English. Not the Planner, which
    # keeps the user's language. Placed before extraArgs: claude takes the last --settings whole (no merge), so a --settings in
    # extraArgs replaces this one and should carry its own "language". It also keeps superpowers out of the workers even when a project or the
    # user enables it (only those two plugin ids); a --settings in extraArgs replaces it whole.
    [ "$ROLE" != planner ] && ARGS+=(--settings '{"language":"english","enabledPlugins":{"superpowers@superpowers-marketplace":false,"superpowers@claude-plugins-official":false}}')
    # settings.superpowers = false: "off" also means off for a superpowers the user installed (the Planner has no other kit --settings)
    [ "$ROLE" = planner ] && [ "$SP_OFF" = 1 ] && ARGS+=(--settings '{"enabledPlugins":{"superpowers@superpowers-marketplace":false,"superpowers@claude-plugins-official":false}}')
    add_list extraArgs
    [ -n "$RESUME" ] && ARGS+=(--resume "$RESUME")
    record_provenance claude || true
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
    # With settings.trust "never" it is left out and codex asks.
    [ "$(trust_of "$CFG")" = never ] || ARGS+=(-c "$(jq -nr --arg p "$(pwd -P)" '"projects={\($p | @json) = {trust_level = \"trusted\"}}"')")
    # MCP servers as configuration overrides (-c mcp_servers.<name>.<field>=...), without touching ~/.codex/config.toml
    if [ -n "$MCPFILE" ]; then while IFS= read -r o; do [ -n "$o" ] && ARGS+=(-c "$o"); done < <(codex_mcp_overrides "$MCPFILE"); fi
    # The same anchor as claude's, as developer instructions, which /new keeps (they replace those of ~/.codex/config.toml)
    ARGS+=(-c "developer_instructions=$(role_anchor "$CFG" "$ROLE" | jq -Rs .)")
    add_list extraArgs
    record_provenance codex || true
    exec "${RUN[@]+"${RUN[@]}"}" codex ${ARGS[@]+"${ARGS[@]}"}   # safe form for an empty list in bash 3.2 (macOS)
    ;;
  opencode)
    # OpenCode 2.x: `opencode mini` takes --agent and --model (the main TUI takes neither). The role's system prompt is a project agent
    # file that opencode-prepare.sh writes in the worktree. It takes its working directory from $PWD, so PWD is the physical path.
    if [ "$(rcfg "$CFG" "$ROLE" mcp | jq -r 'if type == "array" then length else 0 end' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
      echo "agent.sh: $ROLE (opencode) does not get the kit's MCP servers; configure them in OpenCode itself." >&2
    fi
    ORCA_ROLES_CONFIG="$CFG" "$KIT/bin/opencode-prepare.sh" "$ROLE" || { echo "agent.sh: could not prepare the OpenCode agent for $ROLE" >&2; exit 1; }
    cd "$(pwd -P)"; PWD="$(pwd -P)"; export PWD
    ARGS+=(mini --agent "orca-$ROLE")
    [ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
    N0=${#ARGS[@]}; add_list extraArgs
    # Own session id, saved in the git dir, so close-role.sh/launch.sh/clean.sh can delete or continue the role's session. A session flag in
    # extraArgs means the user owns the sessions: nothing is added or saved. --resume <id> (from launch.sh) continues that session.
    OWN=0; i=$N0
    while [ "$i" -lt "${#ARGS[@]}" ]; do case "${ARGS[$i]}" in --session|--session=*|-s|--continue|-c|--fork|--fork=*) OWN=1;; esac; i=$((i + 1)); done
    if [ "$OWN" = 1 ]; then
      [ -z "$RESUME" ] || echo "agent.sh: --resume ignored; $ROLE (opencode) has a session flag in extraArgs and keeps its own sessions." >&2
    else
      OCID="$RESUME"; [ -n "$OCID" ] || OCID="ses_orca_$(printf '%s' "$ROLE" | tr -c 'A-Za-z0-9_-' _)_$(date +%s)$$$RANDOM"
      if OCF="$(oc_session_file "$ROLE")"; then
        printf '%s\n' "$OCID" > "$OCF.tmp.$$" && mv "$OCF.tmp.$$" "$OCF" || echo "agent.sh: could not save the OpenCode session id of $ROLE" >&2
      fi
      ARGS+=(--session "$OCID")
    fi
    record_provenance opencode || true
    exec "${RUN[@]+"${RUN[@]}"}" opencode "${ARGS[@]}"
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
    ORCA_ROLES_ANCHOR="$(role_anchor "$CFG" "$ROLE")"; export ORCA_ROLES_ANCHOR; Q_ANCHOR="$(printf '%q' "$ORCA_ROLES_ANCHOR")"
    CMD="${CMD//\{model\}/$Q_MODEL}"; CMD="${CMD//\{prompts\}/$Q_PROMPTS}"; CMD="${CMD//\{prompt\}/$Q_PROMPT}"; CMD="${CMD//\{mcp\}/$Q_MCP}"; CMD="${CMD//\{scratch\}/$Q_SCRATCH}"
    CMD="${CMD//\{anchor\}/$Q_ANCHOR}"
    DIRFLAG="$(rstr "$CFG" "$ROLE" addDirFlag)"
    if [ -n "$DIRFLAG" ]; then
      [ -n "${SD:-}" ] && ARGS+=("$DIRFLAG" "$SD")
      add_list extraDirs "$DIRFLAG" path
    fi
    add_list extraArgs
    for a in "${ARGS[@]+"${ARGS[@]}"}"; do CMD="$CMD $(printf '%q' "$a")"; done
    record_provenance "" || true
    exec "${RUN[@]+"${RUN[@]}"}" bash -lc "$CMD"
    ;;
  *) echo "Unknown agent for $ROLE: $AGENT (use claude, codex, opencode or custom)" >&2; exit 1;;
esac
