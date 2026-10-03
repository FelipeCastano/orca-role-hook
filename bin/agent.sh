#!/usr/bin/env bash
# Lanza el agente de un rol según la configuración.  Uso: agent.sh <rol>
set -euo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
ROLE="$1"
CFG="${ORCA_ROLES_CONFIG:-}"
if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then CFG="$(mktemp)"; merged_config . > "$CFG"; fi

AGENT="$(rstr "$CFG" "$ROLE" agent)"; AGENT="${AGENT:-claude}"
MODEL="$(rstr "$CFG" "$ROLE" model)"
PERM="$(rstr "$CFG" "$ROLE" permissionMode)"
PROMPT="$(prompt_of "$CFG" "$ROLE")"

# Variables de entorno del rol (defaults.env + roles.<rol>.env)
while IFS=$'\t' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < <(jq -r --arg r "$ROLE" '((.defaults.env // {}) * (.roles[$r].env // {})) | to_entries[] | "\(.key)\t\(.value)"' "$CFG")

# Servidores MCP del rol, en un archivo con formato mcpServers. Con mcp="all" no se genera: el agente usa su propia configuración.
MCPFILE=""
if [ "$(rcfg "$CFG" "$ROLE" mcp)" != '"all"' ]; then
  role_context "$CFG" "$ROLE" .          # placeholders {worktree}, {project}, {evidenceDir}, {browserState}...
  ensure_browser_state "$ORCA_ROLES_BROWSER_STATE"
  # En la carpeta git del worktree, uno por rol, reescrito en cada arranque (fuera de un repo, un temporal)
  if GD="$(git rev-parse --git-dir 2>/dev/null)"; then MCPFILE="$(cd "$GD" && pwd)/orca-roles-mcp-$ROLE.json"; else MCPFILE="$(mktemp)"; fi
  mcp_file "$CFG" "$ROLE" > "$MCPFILE"
  export ORCA_ROLES_MCP="$MCPFILE"
fi

ARGS=()
add_list() {  # $1 campo (array), $2 flag opcional por elemento
  while IFS= read -r x; do [ -n "$x" ] || continue; if [ -n "${2:-}" ]; then ARGS+=("$2" "$x"); else ARGS+=("$x"); fi
  done < <(rcfg "$CFG" "$ROLE" "$1" | jq -r '.[]?' 2>/dev/null)
}

case "$AGENT" in
  claude)
    [ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
    [ -n "$PERM" ] && [ "$PERM" != default ] && ARGS+=(--permission-mode "$PERM")
    ARGS+=(--add-dir "$KIT/prompts")
    PDIR="$(dirname "$PROMPT")"
    [ "$PDIR" != "$KIT/prompts" ] && [ -d "$PDIR" ] && ARGS+=(--add-dir "$PDIR")
    add_list extraDirs --add-dir
    if [ -n "$MCPFILE" ]; then
      ARGS+=(--strict-mcp-config --mcp-config "$MCPFILE")
      export ENABLE_CLAUDEAI_MCP_SERVERS=false
    fi
    TOOLS=(); while IFS= read -r t; do [ -n "$t" ] && TOOLS+=("$t"); done < <(rcfg "$CFG" "$ROLE" allowedTools | jq -r '.[]?')
    [ ${#TOOLS[@]} -gt 0 ] && ARGS+=(--allowedTools "${TOOLS[@]}")
    add_list extraArgs
    exec claude "${ARGS[@]}"
    ;;
  codex)
    [ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
    [ "$PERM" = auto ] && ARGS+=(--full-auto)
    # Servidores MCP como overrides de configuración (-c mcp_servers.<nombre>.<campo>=...), sin tocar ~/.codex/config.toml
    if [ -n "$MCPFILE" ]; then while IFS= read -r o; do [ -n "$o" ] && ARGS+=(-c "$o"); done < <(codex_mcp_overrides "$MCPFILE"); fi
    add_list extraArgs
    exec codex ${ARGS[@]+"${ARGS[@]}"}   # forma segura con lista vacía en bash 3.2 (macOS)
    ;;
  custom)
    # El comando se ejecuta en un shell de login (PATH de tu perfil). Placeholders:
    #   {model} → campo model;  {prompts} → carpeta de prompts del kit;  {prompt} → archivo de prompt del rol
    #   {mcp}   → archivo {"mcpServers": {...}} con los servidores del rol (vacío si mcp="all"); también en $ORCA_ROLES_MCP
    # Se añaden extraArgs al final. permissionMode, allowedTools y extraDirs no se aplican (son de claude).
    CMD="$(rstr "$CFG" "$ROLE" command)"
    [ -n "$CMD" ] || { echo "El rol $ROLE es 'custom' pero no tiene 'command'." >&2; exit 1; }
    Q_MODEL="$(printf '%q' "$MODEL")"; Q_PROMPTS="$(printf '%q' "$KIT/prompts")"; Q_PROMPT="$(printf '%q' "$PROMPT")"
    Q_MCP=""; [ -n "$MCPFILE" ] && Q_MCP="$(printf '%q' "$MCPFILE")"
    CMD="${CMD//\{model\}/$Q_MODEL}"; CMD="${CMD//\{prompts\}/$Q_PROMPTS}"; CMD="${CMD//\{prompt\}/$Q_PROMPT}"; CMD="${CMD//\{mcp\}/$Q_MCP}"
    add_list extraArgs
    for a in "${ARGS[@]+"${ARGS[@]}"}"; do CMD="$CMD $(printf '%q' "$a")"; done
    exec bash -lc "$CMD"
    ;;
  *) echo "Agente desconocido para $ROLE: $AGENT (usa claude, codex o custom)" >&2; exit 1;;
esac
