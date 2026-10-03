#!/usr/bin/env bash
# Asistente para crear un rol nuevo: pregunta su configuración y su prompt, y actualiza todo.
#
#   nuevo-rol                      # guarda el rol en tu instalación (~/.orca-roles)
#   nuevo-rol --repo <ruta-clon>   # lo guarda en tu clon del repo (versionado) y reinstala
set -euo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
TTY="${NEW_ROLE_TTY:-/dev/tty}"
exec 3< "$TTY"   # entrada interactiva aunque el script se ejecute desde una tubería

REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2;;
    -h|--help) sed -n 2,5p "$0"; exit 0;;
    *) echo "Opción desconocida: $1" >&2; exit 1;;
  esac
done

# ---------- utilidades de entrada ----------
ask() {  # ask <variable> <pregunta> [defecto]
  local __v="$1" __q="$2" __d="${3:-}" __a
  if [ -n "$__d" ]; then read -r -u 3 -p "$__q [$__d]: " __a; else read -r -u 3 -p "$__q: " __a; fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}
ask_yn() {  # ask_yn <pregunta> <s|n> → 0 si sí
  local a; read -r -u 3 -p "$1 [$( [ "$2" = s ] && echo S/n || echo s/N )]: " a; a="${a:-$2}"
  case "$a" in s|S|si|sí|y|Y) return 0;; *) return 1;; esac
}
ask_lines() {  # ask_lines <variable> <pregunta>: varias líneas, termina con una vacía
  local __v="$1" __l __acc=""
  echo "$2 (una por línea; línea vacía para terminar):"
  while IFS= read -r -u 3 -p "  > " __l && [ -n "$__l" ]; do __acc="$__acc$__l"$'\n'; done
  printf -v "$__v" '%s' "$__acc"
}
nonempty() { grep "${1:-.}" || true; }
lines_to_json() { printf '%s' "$1" | nonempty | jq -R . | jq -s . ; }
section() { echo; echo "── $1 ──"; }

# ---------- dónde se guarda ----------
if [ -n "$REPO" ]; then
  REPO="$(cd "$REPO" && pwd)"
  [ -f "$REPO/config.default.json" ] && [ -d "$REPO/prompts" ] || { echo "$REPO no parece un clon de orca-roles." >&2; exit 1; }
  TARGET_CFG="$REPO/config.default.json"
  PROMPT_DIR="$REPO/prompts"
  echo "Modo repo: el rol se guarda en $REPO (recuerda hacer commit)."
else
  [ -f "$KIT/config.json" ] || cp "$KIT/config.default.json" "$KIT/config.json"
  TARGET_CFG="$KIT/config.json"
  PROMPT_DIR="$KIT/roles"          # no se borra al actualizar el kit
  echo "Modo local: el rol se guarda en tu instalación ($TARGET_CFG)."
fi
mkdir -p "$PROMPT_DIR"

# ---------- identidad ----------
section "Identidad"
while :; do
  ask ID "Identificador del rol (minúsculas y guiones, p. ej. security-reviewer)"
  [[ "$ID" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "  Formato no válido."; continue; }
  [ "$ID" = planner ] && { echo "  'planner' está reservado."; continue; }
  if jq -e --arg r "$ID" '.roles | has($r)' "$TARGET_CFG" >/dev/null; then
    ask_yn "  Ya existe '$ID'. ¿Sobrescribirlo?" n && break || continue
  fi
  break
done
DEF_TITLE="$(echo "$ID" | awk -F- '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1' OFS=-)"
ask TITLE "Título de la pestaña" "$DEF_TITLE"
ask DESC "Descripción para el Planner: qué hace y cuándo debe usarlo"
while [ -z "$DESC" ]; do ask DESC "  La descripción es obligatoria (el Planner la usa para integrarlo en el flujo)"; done

# ---------- agente y modelo ----------
section "Agente"
ask AGENT "Agente (claude | codex | custom)" "claude"
case "$AGENT" in claude|codex|custom) ;; *) echo "Agente no válido: $AGENT" >&2; exit 1;; esac
DEF_MODEL=""; [ "$AGENT" = claude ] && DEF_MODEL="claude-sonnet-5-5"
ask MODEL "Modelo exacto (vacío = el del agente por defecto)" "$DEF_MODEL"
COMMAND=""
if [ "$AGENT" = custom ]; then
  ask COMMAND "Comando a ejecutar (admite {model} y {prompts})"
  [ -n "$COMMAND" ] || { echo "Un agente custom necesita comando." >&2; exit 1; }
fi
ask PERM "Modo de permisos (auto | acceptEdits | default)" "auto"

# ---------- MCP (cualquier agente) y herramientas (solo claude) ----------
MCP_JSON='[]'; TOOLS_JSON='null'; DIRS_JSON='[]'; NEW_SERVERS='{}'
section "MCP"
{
  AVAIL="$(jq -r '.mcpServers // {} | keys | join(", ")' "$TARGET_CFG")"
  echo "Servidores definidos: ${AVAIL:-ninguno}"
  while ask_yn "¿Añadir un servidor MCP nuevo a la configuración?" n; do
    ask SNAME "  Nombre"
    ask STYPE "  Tipo (http | stdio)" "http"
    if [ "$STYPE" = http ]; then
      ask SURL "  URL"
      NEW_SERVERS="$(jq --arg n "$SNAME" --arg u "$SURL" '. + {($n): {type:"http", url:$u}}' <<<"$NEW_SERVERS")"
    else
      ask SCMD "  Comando (p. ej. npx)"
      ask SARGS "  Argumentos separados por espacios (p. ej. -y @org/mcp@latest)"
      NEW_SERVERS="$(jq --arg n "$SNAME" --arg c "$SCMD" --arg a "$SARGS" '. + {($n): {command:$c, args:($a | split(" ") | map(select(. != "")))}}' <<<"$NEW_SERVERS")"
    fi
    AVAIL="${AVAIL:+$AVAIL, }$SNAME"
  done
  ask MCPSEL "MCP del rol: 'all' (la configuración propia del agente), 'none', o nombres separados por comas" "none"
  case "$MCPSEL" in
    all) MCP_JSON='"all"';;
    none|"") MCP_JSON='[]';;
    *) MCP_JSON="$(echo "$MCPSEL" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | nonempty | jq -R . | jq -s .)";;
  esac
  [ "$AGENT" = custom ] && [ "$MCP_JSON" != '"all"' ] && echo "  Recuerda usar {mcp} (o \$ORCA_ROLES_MCP) en el comando para pasarle el archivo de servidores al agente."
}
if [ "$AGENT" = claude ]; then
  section "Herramientas"
  if ! ask_yn "¿Usar las herramientas permitidas por defecto (orca orchestration y Read)?" s; then
    ask_lines TOOLS "Herramientas permitidas sin preguntar (p. ej. Bash(npm test:*))"
    TOOLS_JSON="$(lines_to_json "$TOOLS")"
  fi
  ask_lines DIRS "Carpetas extra a las que puede acceder"
  DIRS_JSON="$(lines_to_json "$DIRS")"
fi

# ---------- otros ----------
section "Otros"
ask EXTRA "Argumentos extra para el CLI, separados por espacios (opcional)"
EXTRA_JSON="$(jq -n --arg a "$EXTRA" '$a | split(" ") | map(select(. != ""))')"
ask_lines ENVS "Variables de entorno como CLAVE=valor"
ENV_JSON="$(printf '%s' "$ENVS" | nonempty '=' | jq -R 'split("=") | {(.[0]): (.[1:] | join("="))}' | jq -s 'add // {}')"
ask_lines PARAMS "Parámetros del rol como clave=valor (p. ej. maxFindings=20)"
PARAMS_JSON="$(printf '%s' "$PARAMS" | nonempty '=' | jq -R 'split("=") | {(.[0]): ((.[1:] | join("=")) as $v | try ($v | fromjson) catch $v)}' | jq -s 'add // {}')"

echo "Orden actual: $(jq -r '.roles | keys_unsorted | join(" → ")' "$TARGET_CFG")"
LAST="$(jq -r '.roles | keys_unsorted | map(select(. != "'"$ID"'")) | last' "$TARGET_CFG")"
ask AFTER "Colocar la pestaña después de" "$LAST"
jq -e --arg r "$AFTER" '.roles | has($r)' "$TARGET_CFG" >/dev/null || { echo "No existe el rol '$AFTER'." >&2; exit 1; }
ENABLED=true; ask_yn "¿Activarlo ya?" s || ENABLED=false

# ---------- prompt ----------
# Todos los prompts siguen el mismo patrón: misión, "Cuando recibas una tarea", "Límites", "Parámetros", "Reporte" y cierre.
section "Prompt"
PROMPT_FILE="$PROMPT_DIR/$ID.md"
echo "1) Generarlo a partir de unas preguntas"
echo "2) Usar un archivo que ya tengo"
echo "3) Escribirlo en el editor (${EDITOR:-nano})"
ask PMODE "Opción" "1"
write_skeleton() {  # write_skeleton <mision> <pasos> <limites> <reporte> <veredicto 0|1>
  local mission="$1" resp="$2" limits="$3" report="$4" verdict="$5"
  {
    echo "# Rol: $(echo "$TITLE" | tr 'a-z' 'A-Z')"
    echo
    echo "$mission"
    echo
    echo "## Cuando recibas una tarea"
    if [ -n "$resp" ]; then n=1; printf '%s' "$resp" | nonempty | while IFS= read -r l; do echo "$n. $l"; n=$((n+1)); done; else echo "1. "; fi
    echo
    echo "## Límites"
    if [ -n "$limits" ]; then printf '%s' "$limits" | nonempty | sed 's/^/- /'; else echo "- "; fi
    echo
    echo "## Parámetros"
    if [ "$PARAMS_JSON" != "{}" ]; then
      echo "Si no vienen en tu mensaje de arranque, usa estos valores:"
      jq -r 'to_entries[] | "- `\(.key)`: \(.value)"' <<<"$PARAMS_JSON"
    else
      echo "Ninguno."
    fi
    echo
    echo "## Reporte"
    echo "Reporta con \`worker_done\`:"
    if [ "$verdict" = 1 ]; then
      echo '- `--subject`: `VEREDICTO: ACEPTADO` o `VEREDICTO: RECHAZADO`'
      echo '- `--body`: primera línea igual al subject, y además:'
    else
      echo '- `--subject`: resultado en una línea'
      echo '- `--body`:'
    fi
    if [ -n "$report" ]; then printf '%s' "$report" | nonempty | sed 's/^/  - /'; else echo "  - "; fi
    echo '- `--files-modified` con las rutas que hayas creado o cambiado'
    if [ "$verdict" = 1 ]; then echo '- `--outcome succeeded` cuando la tarea se completó, aunque rechaces'
    else echo '- `--outcome succeeded` si completaste la tarea'; fi
    echo; echo "Ahora responde solo \"$TITLE listo\" y espera tareas."
  } > "$PROMPT_FILE"
}
case "$PMODE" in
  1)
    ask MISSION "Misión del rol en una frase" "$DESC"
    ask_lines RESP "Qué hace cuando recibe una tarea (pasos)"
    ask_lines LIMITS "Límites: qué NO debe hacer"
    ask_lines REPORT "Qué debe incluir su reporte"
    ask_yn "¿Emite un veredicto ACEPTADO/RECHAZADO?" n && VERDICT=1 || VERDICT=0
    write_skeleton "$MISSION" "$RESP" "$LIMITS" "$REPORT" "$VERDICT"
    ask_yn "¿Abrirlo en el editor para revisarlo?" n && "${EDITOR:-nano}" "$PROMPT_FILE" < "$TTY" > "$TTY"
    ;;
  2)
    ask SRCF "Ruta del archivo"; SRCF="${SRCF/#\~/$HOME}"
    [ -f "$SRCF" ] || { echo "No existe $SRCF" >&2; exit 1; }
    cp "$SRCF" "$PROMPT_FILE"
    grep -q '^## Reporte' "$PROMPT_FILE" || echo "Aviso: el prompt no tiene sección '## Reporte'; revisa que siga el patrón del resto de roles (ver README → Crear un rol nuevo)."
    ;;
  3)
    write_skeleton "$DESC" "" "" "" 0
    "${EDITOR:-nano}" "$PROMPT_FILE" < "$TTY" > "$TTY"
    ;;
  *) echo "Opción no válida" >&2; exit 1;;
esac

# ---------- construir el rol y guardar ----------
PROMPT_FIELD=""; [ -z "$REPO" ] && PROMPT_FIELD="$PROMPT_FILE"   # en el repo vale la ruta por defecto (prompts/<id>.md)
ROLE_JSON="$(jq -n \
  --arg title "$TITLE" --arg desc "$DESC" --argjson enabled "$ENABLED" \
  --arg agent "$AGENT" --arg model "$MODEL" --arg perm "$PERM" --arg command "$COMMAND" \
  --argjson mcp "$MCP_JSON" --argjson tools "$TOOLS_JSON" --argjson dirs "$DIRS_JSON" \
  --argjson extra "$EXTRA_JSON" --argjson env "$ENV_JSON" --argjson params "$PARAMS_JSON" \
  --arg prompt "$PROMPT_FIELD" '
  {title:$title, description:$desc, enabled:$enabled, agent:$agent}
  + (if $model != "" then {model:$model} else {} end)
  + (if $perm != "auto" then {permissionMode:$perm} else {} end)
  + (if $command != "" then {command:$command} else {} end)
  + {mcp:$mcp}
  + (if $tools != null then {allowedTools:$tools} else {} end)
  + (if ($dirs | length) > 0 then {extraDirs:$dirs} else {} end)
  + (if ($extra | length) > 0 then {extraArgs:$extra} else {} end)
  + (if ($env | length) > 0 then {env:$env} else {} end)
  + (if ($params | length) > 0 then {params:$params} else {} end)
  + (if $prompt != "" then {prompt:$prompt} else {} end)')"

section "Resumen"
echo "Rol '$ID' (después de '$AFTER'):"
jq . <<<"$ROLE_JSON"
[ "$NEW_SERVERS" != "{}" ] && { echo "Servidores MCP nuevos:"; jq . <<<"$NEW_SERVERS"; }
echo "Prompt: $PROMPT_FILE"
ask_yn "¿Guardar?" s || { echo "Cancelado (el prompt quedó en $PROMPT_FILE)."; exit 1; }

cp "$TARGET_CFG" "$TARGET_CFG.bak"
TMPC="$(mktemp)"
jq --arg id "$ID" --arg after "$AFTER" --argjson role "$ROLE_JSON" --argjson servers "$NEW_SERVERS" '
  .mcpServers = ((.mcpServers // {}) + $servers)
  | .roles = (.roles | to_entries | map(select(.key != $id))
      | (map(.key) | index($after)) as $i
      | (.[0:$i+1] + [{key:$id, value:$role}] + .[$i+1:]) | from_entries)' "$TARGET_CFG" > "$TMPC"
jq empty "$TMPC" && mv "$TMPC" "$TARGET_CFG"
echo "Configuración actualizada: $TARGET_CFG (copia anterior en $TARGET_CFG.bak)"

if [ -n "$REPO" ]; then
  if ask_yn "¿Reinstalar el kit desde el repo para aplicarlo ya?" s; then bash "$REPO/install.sh"; fi
  echo "Recuerda: cd $REPO && git add -A && git commit -m \"Nuevo rol: $ID\" && git push"
fi
echo "Listo. El rol '$TITLE' aparecerá en los worktrees que crees a partir de ahora (o con 'roles' en uno existente)."
