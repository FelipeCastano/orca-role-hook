# shellcheck shell=bash
# Funciones compartidas. Requiere jq. Compatibles con bash 3.2 (macOS) y con GNU/BSD.
KIT="${KIT:-$HOME/.orca-roles}"

# El CLI de Orca no siempre se llama 'orca': en las terminales de WSL que gestiona Orca en Windows es $ORCA_CLI_COMMAND
# (p. ej. orca-ide). Si 'orca' no está en el PATH pero Orca indica otro nombre, se crea el envoltorio $KIT/shim/orca y se
# antepone al PATH: los scripts del kit, los prompts y los agentes (que heredan el PATH) siguen usando 'orca'.
orca_shim() {
  local real="${ORCA_CLI_COMMAND:-}" dir="$KIT/shim" tmp
  command -v orca >/dev/null 2>&1 && return 0
  { [ -n "$real" ] && [ "$real" != orca ] && command -v "$real" >/dev/null 2>&1; } || return 0
  mkdir -p "$dir" && tmp="$(mktemp "$dir/.orca.XXXXXX")" || return 0
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real" > "$tmp" && chmod +x "$tmp" && mv "$tmp" "$dir/orca"
  PATH="$dir:$PATH"; export PATH
}
orca_shim

# Config efectiva: ~/.orca-roles/config.json (o la de serie) + .orca-roles.json del proyecto, si existe.
# El .orca-roles.json se busca en la raíz del worktree y, si no está (p. ej. no está commiteado), en la del checkout principal.
merged_config() {  # $1 = carpeta del proyecto/worktree
  local base="$KIT/config.json" proj
  [ -f "$base" ] || base="$KIT/config.default.json"
  proj="$(project_config "${1:-.}")"
  if [ -n "$proj" ]; then jq -s '.[0] * .[1]' "$base" "$proj"; else cat "$base"; fi
}
# Ruta del .orca-roles.json que aplica a una carpeta (vacío si no hay).  project_config <carpeta>
project_config() {
  local top common main
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -f "$top/.orca-roles.json" ] && { echo "$top/.orca-roles.json"; return 0; }
  common="$(cd "$1" && git rev-parse --git-common-dir 2>/dev/null)" || return 0
  main="$(cd "$1" && cd "$common/.." && pwd)"
  [ -f "$main/.orca-roles.json" ] && echo "$main/.orca-roles.json"
  return 0
}
# Valor de un rol con herencia de defaults:  rcfg <config> <rol> <campo>
rcfg() { jq -c --arg r "$2" --arg k "$3" '(.roles[$r][$k]) // (.defaults[$k]) // empty' "$1"; }
rstr() { jq -r --arg r "$2" --arg k "$3" '(.roles[$r][$k]) // (.defaults[$k]) // empty' "$1"; }
setting() { jq -r --arg k "$2" --arg d "$3" '(.settings[$k]) // $d | tostring' "$1"; }
# Roles activos en orden; el planner va siempre
enabled_roles() { jq -r '.roles | to_entries[] | select(.key == "planner" or .value.enabled != false) | .key' "$1"; }
title_of() { jq -r --arg r "$2" '.roles[$r].title // $r' "$1"; }
var_of()   { echo "$1" | tr 'a-z-' 'A-Z_'; }
# Archivo de prompt de un rol: campo "prompt" (admite ~), o prompts/<rol>.md del kit
prompt_of() { local p; p="$(jq -r --arg r "$2" '.roles[$r].prompt // empty' "$1")"; p="${p/#\~/$HOME}"; echo "${p:-$KIT/prompts/$2.md}"; }
# Actualiza una configuración de usuario con las claves/roles nuevos de la de serie, sin pisar valores ni el orden de sus roles.
upgrade_config() {  # $1 = config.default.json, $2 = config.json del usuario → stdout
  jq -s '.[0] as $d | .[1] as $u | ($d * $u) as $m
    | $m | .roles = ((($u.roles | keys_unsorted) + (($d.roles | keys_unsorted) - ($u.roles | keys_unsorted)))
                     | map({key: ., value: $m.roles[.]}) | from_entries)' "$1" "$2"
}
# Excepciones de launch.sh (opciones del setup script del proyecto, o de 'roles') como JSON:
#   {"only": [...], "enable": [...], "disable": [...], "set": [{"path": [...], "value": ...}]}
# overrides_from_args [--only a,b] [--enable a,b] [--disable a,b] [--set ruta.con.puntos=valor] ...  → stdout; 1 si hay un error
# Las listas se acumulan si una opción se repite. En --set el valor se lee como JSON si lo es (true, 10, ["x"]) y si no, como texto.
overrides_from_args() {
  local o='{"only":[],"enable":[],"disable":[],"set":[]}' opt val k
  while [ $# -gt 0 ]; do
    case "$1" in
      --only=*|--enable=*|--disable=*|--set=*) opt="${1%%=*}"; val="${1#*=}";;
      --only|--enable|--disable|--set) opt="$1"; [ $# -ge 2 ] || { echo "ERROR: $1 necesita un valor" >&2; return 1; }; val="$2"; shift;;
      *) echo "ERROR: opción desconocida: $1" >&2; return 1;;
    esac
    shift
    k="${opt#--}"
    if [ "$k" = set ]; then
      case "$val" in *=*) ;; *) echo "ERROR: --set espera ruta=valor (p. ej. roles.dev.model=claude-opus-5-5): $val" >&2; return 1;; esac
      o="$(jq -c --arg p "${val%%=*}" --arg v "${val#*=}" '.set += [{path: ($p | split(".")), value: ($v | try fromjson catch $v)}]' <<<"$o")"
    else
      o="$(jq -c --arg k "$k" --arg v "$val" '.[$k] += ($v | split(",") | map(gsub("^ +| +$"; "")) | map(select(. != "")))' <<<"$o")"
    fi
  done
  printf '%s\n' "$o"
}
# Comprueba que las excepciones solo nombran roles que existen y no desactivan al planner.  check_overrides <config> <overrides>
check_overrides() {
  jq -r --slurpfile o "$2" '(.roles | keys) as $ks | $o[0] as $o
    | ([$o.only[], $o.enable[], $o.disable[]] | unique | map(select(. as $r | $ks | index($r) | not))
       | if length > 0 then "ERROR: roles desconocidos: \(join(", ")). Disponibles: \($ks | join(", "))" else empty end),
      (if ($o.disable | index("planner")) then "ERROR: el planner no se puede desactivar" else empty end)' "$1"
}
# Aplica las excepciones a una configuración: --only (el planner siempre queda), luego --enable, --disable y --set.  apply_overrides <config> <overrides>
apply_overrides() {
  jq --slurpfile o "$2" '$o[0] as $o
    | if ($o.only | length) > 0 then .roles |= with_entries(.value.enabled = (.key == "planner" or (.key as $k | $o.only | index($k)) != null)) else . end
    | reduce $o.enable[] as $r (.; .roles[$r].enabled = true)
    | reduce $o.disable[] as $r (.; .roles[$r].enabled = false)
    | reduce $o.set[] as $s (.; setpath($s.path; $s.value))' "$1"
}
# Escapa un texto para usarlo literalmente dentro de una expresión regular
regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|\\]/\\&/g'; }
# Clave de Jira del worktree.  jira_key <rama> <jiraIdentifier de Orca> <url del ticket>
# Orca guarda el ticket de un worktree enlazado en linkedWorkItem (provider "jira", jiraIdentifier, url): manda eso.
# Sin enlace (worktree creado a mano, 'roles' en un checkout), se toma de la rama solo si la clave, en mayúsculas,
# abre la rama o uno de sus segmentos (DEVGD-220-x, feature/DEVGD-220), para no confundir fix-123 o release-1.4 con un ticket.
jira_key() {
  local k=""
  if [ -n "$2" ]; then k="$2"
  elif [ -n "$3" ]; then k="$(printf '%s' "$3" | grep -oE 'browse/[A-Za-z][A-Za-z0-9_]+-[0-9]+' | head -1)"; k="${k#browse/}"
  else k="$(printf '%s' "$1" | grep -oE '(^|/)[A-Z][A-Z0-9_]+-[0-9]+' | head -1)"; k="${k#/}"
  fi
  printf '%s' "$k" | tr 'a-z' 'A-Z'
}
# Expresión (jq, sin distinguir mayúsculas) que debe cumplir el título de la sesión extra del composer para cerrarla:
# empieza por la clave de Jira seguida de un separador o del final ("DEVGD-220", "DEVGD-220: resumen"),
# o es exactamente el nombre de la rama. Vacía si no hay ni clave ni rama.  composer_title_regex <clave> <rama>
composer_title_regex() {
  local alts=""
  [ -n "$1" ] && alts="$(regex_escape "$1")([^A-Za-z0-9_-].*)?"
  [ -n "$2" ] && alts="${alts:+$alts|}$(regex_escape "$2")"
  [ -n "$alts" ] && printf '^(%s)$' "$alts"
  return 0
}
# Mensaje de arranque del Planner.  planner_msg <config> "<roles activos>" <state> <jira_key> <jira_url> <retomar 0|1>
planner_msg() {
  local cfg="$1" roles="$2" state="$3" key="$4" url="$5" resume="$6" id v t handles="" active="" extra params msg
  # shellcheck source=/dev/null
  . "$state"
  for id in $roles; do
    [ "$id" = planner ] && continue
    v="$(var_of "$id")"; t="$(title_of "$cfg" "$id")"
    handles="$handles $t=${!v},"; active="$active $t"
  done
  extra="$(jq -r --argjson act "$(printf '%s\n' $roles | grep . | jq -R . | jq -s .)" \
    '[.roles | to_entries[] | select(.key != "planner" and (.key as $k | $act | index($k)) and .value.description) | "\(.value.title // .key): \(.value.description)"] | join("; ")' "$cfg")"
  params="$(jq -r '((.defaults.params // {}) * (.roles.planner.params // {})) | to_entries | map("\(.key)=\(.value)") | join(", ")' "$cfg")"
  msg="Lee $(prompt_of "$cfg" planner) y adopta ese rol desde ahora. Roles activos en este workspace:${active:- ninguno}. Handles:${handles%,}."
  [ -n "$params" ] && msg="$msg Parámetros de configuración: $params."
  [ -n "$extra" ] && msg="$msg Roles adicionales (intégralos en el flujo según su descripción): $extra."
  if [ "$(setting "$cfg" cleanWorkersAfterStep true)" = true ]; then msg="$msg Al cerrar cada paso, propón al usuario limpiar el contexto de los workers (ver tu sección «Limpiar el contexto de los workers»)."
  else msg="$msg Limpia el contexto de los workers solo si el usuario te lo pide."; fi
  [ -n "$key" ] && msg="$msg Este worktree está vinculado al ticket de Jira $key${url:+ ($url)}: léelo con Jira y úsalo como punto de partida de la planificación."
  if [ "$resume" = 1 ]; then
    msg="$msg ATENCIÓN: este workspace se está RETOMANDO tras un reinicio. Las terminales anteriores del equipo murieron y los handles de arriba son nuevos. Antes de hablar con el usuario, sigue la sección «Retomar un workspace tras un reinicio» de tu prompt: recupera el Run, las tareas, las últimas comunicaciones y el estado del código, y preséntale un resumen. Empieza por ahí."
  else
    msg="$msg Empieza con el arranque."
  fi
  printf '%s' "$msg"
}
# Parámetros de un rol (defaults.params + roles.<rol>.params) como "k=v, k=v"
params_of() { jq -r --arg r "$2" '((.defaults.params // {}) * (.roles[$r].params // {})) | to_entries | map("\(.key)=\(.value)") | join(", ")' "$1"; }
# Mensaje de arranque de un worker.  worker_msg <config> <rol>
worker_msg() {
  local p; p="$(params_of "$1" "$2")"
  printf '%s' "Lee $KIT/prompts/comun-workers.md y $(prompt_of "$1" "$2") y adopta ese rol desde ahora. Sigue sus instrucciones al pie de la letra.${p:+ Parámetros de configuración: $p.}"
}
# Comando que abre una conversación nueva en el agente de un rol (campo clearCommand, o el propio del agente)
clear_command() {
  local c; c="$(rstr "$1" "$2" clearCommand)"
  if [ -n "$c" ]; then echo "$c"; return; fi
  case "$(rstr "$1" "$2" agent)" in claude|"") echo "/clear";; codex) echo "/new";; *) ;; esac
}
# Servidores MCP de un rol como archivo {"mcpServers": {...}} (formato de Claude Code, Cursor y Gemini CLI).  mcp_file <config> <rol>
# En los args, env y url de los servidores se expanden los placeholders {worktree}, {project}, {evidenceDir}, {browserState}, {kit} y {home}
# (valores de role_context; si no se ha llamado, el worktree es el directorio actual).
mcp_file() {
  jq --arg r "$2" \
     --arg worktree "${ORCA_ROLES_WORKTREE:-$PWD}" --arg project "${ORCA_ROLES_PROJECT:-$(basename "$PWD")}" \
     --arg evidenceDir "${ORCA_ROLES_EVIDENCE_DIR:-qa-evidence}" --arg browserState "${ORCA_ROLES_BROWSER_STATE:-$KIT/browser/default.json}" \
     --arg kit "$KIT" --arg home "$HOME" '
    ((.roles[$r].mcp) // (.defaults.mcp) // []) as $names | (.mcpServers // {}) as $s
    | (if ($names | type) == "array" then $names else [] end) as $names
    | {mcpServers: ([$names[] | select($s[.] != null) | {(.): $s[.]}] | add // {})}
    | walk(if type == "string" then
        gsub("\\{worktree\\}"; $worktree) | gsub("\\{project\\}"; $project) | gsub("\\{evidenceDir\\}"; $evidenceDir)
        | gsub("\\{browserState\\}"; $browserState) | gsub("\\{kit\\}"; $kit) | gsub("\\{home\\}"; $home)
      else . end)' "$1"
}
# Los mismos servidores como overrides -c de Codex (mcp_servers.<nombre>.<campo>=<valor TOML>), uno por línea.  codex_mcp_overrides <archivo mcp>
codex_mcp_overrides() {
  jq -r '.mcpServers | to_entries[] | .key as $n | .value
    | (if .command then "mcp_servers.\($n).command=\(.command | @json)" else empty end),
      (if .command and .args then "mcp_servers.\($n).args=\(.args | @json)" else empty end),
      (if .url then "mcp_servers.\($n).url=\(.url | @json)" else empty end),
      (if .env then "mcp_servers.\($n).env={" + ([.env | to_entries[] | "\(.key) = \(.value | @json)"] | join(", ")) + "}" else empty end)' "$1"
}
# Nombre del proyecto: carpeta del repo principal (no del worktree); si no es un repo, la carpeta dada.  project_name <carpeta>
project_name() {
  local common
  if common="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)"; then
    common="$(cd "$1" && cd "$common" && pwd)"; basename "$(dirname "$common")"
  else basename "$(cd "$1" && pwd)"; fi
}
# Contexto de un rol para los placeholders de mcpServers; exporta ORCA_ROLES_WORKTREE/PROJECT/EVIDENCE_DIR/BROWSER_STATE.  role_context <config> <rol> <worktree>
role_context() {
  ORCA_ROLES_WORKTREE="$(cd "$3" && pwd)"
  ORCA_ROLES_PROJECT="$(project_name "$3")"
  ORCA_ROLES_EVIDENCE_DIR="$(jq -r --arg r "$2" '.roles[$r].params.evidenceDir // .roles["visual-tester"].params.evidenceDir // .defaults.params.evidenceDir // "qa-evidence"' "$1")"
  ORCA_ROLES_BROWSER_STATE="$KIT/browser/$ORCA_ROLES_PROJECT.json"
  export ORCA_ROLES_WORKTREE ORCA_ROLES_PROJECT ORCA_ROLES_EVIDENCE_DIR ORCA_ROLES_BROWSER_STATE
}
# Crea un estado de navegador vacío si no existe (Playwright acepta {"cookies":[],"origins":[]}); browser-login.sh lo rellena.
ensure_browser_state() { [ -f "$1" ] || { mkdir -p "$(dirname "$1")"; echo '{"cookies":[],"origins":[]}' > "$1"; }; }
