#!/usr/bin/env bash
# Pruebas de humo de orca-roles: configuración, herencia, mezcla por proyecto y actualización.
# Uso: tests/smoke.sh   (no toca ~/.orca-roles)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export KIT="$TMP/kit"; mkdir -p "$KIT"
cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$KIT/"; chmod +x "$KIT"/bin/*.sh
. "$KIT/bin/lib.sh"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: esperaba [$3], obtuve [$2]"; FAIL=1; fi; }

# Sintaxis y JSON
for f in "$ROOT"/install.sh "$ROOT"/bin/*.sh "$ROOT"/tests/*.sh; do bash -n "$f"; done; echo "ok   sintaxis bash"
jq empty "$ROOT/config.default.json"; echo "ok   config.default.json es JSON"

# Cada prompt sigue el patrón
for p in "$ROOT"/prompts/*.md; do
  n="$(basename "$p" .md)"; [ "$n" = comun-workers ] && continue
  for sec in '^# Rol: ' '^## Cuando recibas una tarea' '^## Límites' '^## Parámetros' '^## Reporte' '^Ahora responde solo'; do
    [ "$n" = planner ] && case "$sec" in '^## Cuando recibas una tarea'|'^## Reporte'|'^Ahora responde solo') continue;; esac
    grep -qE "$sec" "$p" || { echo "FAIL prompts/$n.md: falta la sección $sec"; FAIL=1; }
  done
done
grep -q '^## Método de revisión de código' "$ROOT/prompts/auditor.md" || { echo "FAIL auditor.md sin método"; FAIL=1; }
grep -q '^## Método de revisión de planes' "$ROOT/prompts/planner.md" || { echo "FAIL planner.md sin método"; FAIL=1; }
grep -q '^## Retomar un workspace tras un reinicio' "$ROOT/prompts/planner.md" || { echo "FAIL planner.md sin sección de retomar"; FAIL=1; }
[ -d "$ROOT/prompts/metodos" ] && { echo "FAIL prompts/metodos no debería existir"; FAIL=1; }
echo "ok   patrón de prompts"

# Cada rol de config tiene prompt
for r in $(jq -r '.roles | keys_unsorted[]' "$KIT/config.default.json"); do
  [ -f "$(prompt_of "$KIT/config.default.json" "$r")" ] || { echo "FAIL rol $r sin prompt"; FAIL=1; }
done; echo "ok   prompts de los roles de serie"

# Herencia de defaults y planner siempre activo
cat > "$KIT/config.json" <<'J'
{ "settings": { "launchWaitSeconds": 3 },
  "defaults": { "agent": "claude", "permissionMode": "auto", "mcp": [], "allowedTools": ["Read"], "params": {} },
  "mcpServers": { "ctx": { "type": "http", "url": "http://x" } },
  "roles": {
    "planner": { "title": "Planner", "enabled": false, "mcp": "all" },
    "dev": { "title": "Dev", "model": "m-dev", "mcp": ["ctx"], "permissionMode": "acceptEdits" },
    "tester": { "title": "Tester", "enabled": false },
    "extra": { "title": "Extra", "agent": "custom", "command": "foo {model}", "prompt": "~/x/extra.md" }
  } }
J
C="$KIT/config.json"
check "planner siempre activo aunque enabled=false" "$(enabled_roles "$C" | tr '\n' ' ')" "planner dev extra "
check "rstr hereda de defaults" "$(rstr "$C" dev agent)" "claude"
check "rstr prefiere el rol" "$(rstr "$C" dev permissionMode)" "acceptEdits"
check "rcfg mcp del rol" "$(rcfg "$C" dev mcp)" '["ctx"]'
check "rcfg mcp all" "$(rcfg "$C" planner mcp)" '"all"'
check "rcfg vacío cuando no hay valor" "$(rcfg "$C" dev command)" ""
check "setting con defecto" "$(setting "$C" kickoffTimeoutSeconds 180)" "180"
check "setting definido" "$(setting "$C" launchWaitSeconds 15)" "3"
check "title_of" "$(title_of "$C" dev)" "Dev"
check "title_of sin título" "$(title_of "$C" nuevo)" "nuevo"
check "var_of" "$(var_of visual-tester)" "VISUAL_TESTER"
check "prompt_of por defecto" "$(prompt_of "$C" dev)" "$KIT/prompts/dev.md"
check "prompt_of con ~" "$(prompt_of "$C" extra)" "$HOME/x/extra.md"
check "regex_escape" "$(regex_escape 'feat/DEV-1.x+(y)')" 'feat/DEV-1\.x\+\(y\)'

# Mezcla con .orca-roles.json del proyecto (objetos campo a campo, listas enteras)
PROJ="$TMP/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
echo '{ "roles": { "dev": { "mcp": [] }, "tester": { "enabled": true } }, "settings": { "jiraHandoff": false } }' > "$PROJ/.orca-roles.json"
M="$(merged_config "$PROJ")"
check "mezcla: lista sustituida" "$(echo "$M" | jq -c '.roles.dev.mcp')" '[]'
check "mezcla: campo conservado" "$(echo "$M" | jq -r '.roles.dev.model')" 'm-dev'
check "mezcla: rol reactivado" "$(echo "$M" | jq -r '.roles.tester.enabled')" 'true'
check "mezcla: setting del proyecto" "$(echo "$M" | jq -r '.settings.jiraHandoff')" 'false'
check "mezcla: setting global conservado" "$(echo "$M" | jq -r '.settings.launchWaitSeconds')" '3'
check "sin .orca-roles.json devuelve la global" "$(merged_config "$TMP" | jq -r '.roles.tester.enabled')" 'false'

# Actualización: claves nuevas entran, valores y orden del usuario se conservan
U="$(upgrade_config "$KIT/config.default.json" "$C")"
check "upgrade: orden del usuario primero" "$(echo "$U" | jq -r '.roles | keys_unsorted | .[0:4] | join(" ")')" "planner dev tester extra"
check "upgrade: roles nuevos al final" "$(echo "$U" | jq -r '.roles | keys_unsorted | last')" "deployer"
check "upgrade: valor del usuario conservado" "$(echo "$U" | jq -r '.roles.dev.model')" "m-dev"
check "upgrade: enabled del usuario conservado" "$(echo "$U" | jq -r '.roles.tester.enabled')" "false"
check "upgrade: setting nuevo añadido" "$(echo "$U" | jq -r '.settings.kickoffTimeoutSeconds')" "180"
check "upgrade: mcpServers fusionados" "$(echo "$U" | jq -r '.mcpServers | keys | join(" ")')" "atlassian context7 ctx playwright"

# Mensaje de arranque del Planner: handles, Jira, roles adicionales y modo retomar
cat > "$KIT/config.json" <<'J'
{ "defaults": { "params": {} }, "mcpServers": {}, "roles": {
    "planner": { "title": "Planner" }, "dev": { "title": "Dev" },
    "sec": { "title": "Sec", "description": "revisa seguridad" } } }
J
printf 'PLANNER=t1\nDEV=t2\nSEC=t3\n' > "$TMP/state.env"
M1="$(planner_msg "$KIT/config.json" "planner dev sec" "$TMP/state.env" "ABC-1" "https://x.atlassian.net/browse/ABC-1" 0)"
case "$M1" in *"Handles: Dev=t2, Sec=t3."*) echo "ok   planner_msg: handles";; *) echo "FAIL planner_msg handles: $M1"; FAIL=1;; esac
case "$M1" in *"Sec: revisa seguridad"*) echo "ok   planner_msg: roles adicionales";; *) echo "FAIL planner_msg extra: $M1"; FAIL=1;; esac
case "$M1" in *"ticket de Jira ABC-1 (https://x.atlassian.net/browse/ABC-1)"*) echo "ok   planner_msg: jira";; *) echo "FAIL planner_msg jira: $M1"; FAIL=1;; esac
case "$M1" in *"Empieza con el arranque.") echo "ok   planner_msg: arranque normal";; *) echo "FAIL planner_msg arranque: $M1"; FAIL=1;; esac
M2="$(planner_msg "$KIT/config.json" "planner dev" "$TMP/state.env" "" "" 1)"
case "$M2" in *"RETOMANDO"*"Retomar un workspace tras un reinicio"*"Empieza por ahí.") echo "ok   planner_msg: modo retomar";; *) echo "FAIL planner_msg retomar: $M2"; FAIL=1;; esac
case "$M2" in *"Jira"*) echo "FAIL planner_msg sin jira menciona Jira"; FAIL=1;; *) echo "ok   planner_msg: sin jira";; esac
case "$M2" in *"Sec"*) echo "FAIL planner_msg incluye rol inactivo"; FAIL=1;; *) echo "ok   planner_msg: solo roles activos";; esac

# Limpieza de workers: worker_msg, clear_command y clean.sh con un 'orca' simulado
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1 }, "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": {
    "planner": { "title": "Planner" },
    "dev": { "title": "Dev", "params": { "a": 1 } },
    "cx": { "title": "Codex", "agent": "codex" },
    "cu": { "title": "Custom", "agent": "custom", "command": "x" },
    "cc": { "title": "Custom2", "agent": "custom", "command": "x", "clearCommand": "/reset" } } }
J
C="$KIT/config.json"
check "worker_msg con parámetros" "$(worker_msg "$C" dev)" "Lee $KIT/prompts/comun-workers.md y $KIT/prompts/dev.md y adopta ese rol desde ahora. Sigue sus instrucciones al pie de la letra. Parámetros de configuración: a=1."
case "$(worker_msg "$C" cx)" in *"Parámetros"*) echo "FAIL worker_msg sin params menciona parámetros"; FAIL=1;; *) echo "ok   worker_msg sin parámetros";; esac
check "clear_command claude" "$(clear_command "$C" dev)" "/clear"
check "clear_command codex" "$(clear_command "$C" cx)" "/new"
check "clear_command custom sin definir" "$(clear_command "$C" cu)" ""
check "clear_command explícito" "$(clear_command "$C" cc)" "/reset"
printf 'PLANNER=t1\nDEV=t2\nCX=t3\nCU=t4\n' > "$TMP/state.env"
mkdir -p "$TMP/fakebin" "$TMP/home"; ln -sfn "$KIT" "$TMP/home/.orca-roles"   # HOME simulado: ~/.orca-roles → kit de prueba
LOGF="$TMP/orca.log"; : > "$LOGF"
cat > "$TMP/fakebin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$LOGF"
case "\$*" in *"--terminal t3 "*) [ "\$2" = show ] && exit 1;; esac
exit 0
EOS
chmod +x "$TMP/fakebin/orca"
run_clean() { (cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/clean.sh" "$@" 2>&1); }
try() { if OUT="$("$@")"; then RC=0; else RC=$?; fi; }   # captura salida y código sin disparar set -e
try run_clean dev
check "clean.sh dev: resultado" "$RC:$OUT" "0:Dev: contexto limpiado (/clear) y rol reenviado."
check "clean.sh dev: envía /clear, espera y reenvía el rol" "$(grep -c -E 'terminal send --terminal t2 --text /clear --enter|terminal wait --terminal t2 --for tui-idle|terminal send --terminal t2 --text Lee .*dev.md.*a=1\. --enter' "$LOGF")" "3"
try run_clean Codex; check "clean.sh por título y pestaña muerta" "$RC:$OUT" "1:Codex: su pestaña (t3) no responde."
check "clean.sh por handle" "$(run_clean t2)" "Dev: contexto limpiado (/clear) y rol reenviado."
try run_clean planner; check "clean.sh rechaza al planner" "$RC:$OUT" "1:Planner: el Planner no se limpia a sí mismo."
try run_clean cu; check "clean.sh custom sin clearCommand" "$RC" "1"; case "$OUT" in *clearCommand*) echo "ok   clean.sh explica clearCommand";; *) echo "FAIL clean.sh: $OUT"; FAIL=1;; esac
try run_clean nadie; check "clean.sh rol desconocido" "$RC" "1"
: > "$LOGF"; try run_clean --all; check "clean.sh --all: pestaña muerta reportada" "$RC" "1"; case "$OUT" in *"Codex: su pestaña (t3) no responde."*) echo "ok   clean.sh --all: mensaje de pestaña muerta";; *) echo "FAIL clean.sh --all: $OUT"; FAIL=1;; esac
check "clean.sh --all excluye al planner" "$(grep -c 'terminal show --terminal t1' "$LOGF" || true)" "0"
check "clean.sh --all recorre los workers" "$(grep -c 'terminal show' "$LOGF")" "3"
check "clean.sh --msg" "$(run_clean --msg dev | sed "s#$TMP/home/.orca-roles#$KIT#g")" "$(worker_msg "$C" dev)"
rm -f "$TMP/fakebin/orca"
M3="$(planner_msg "$C" "planner dev" "$TMP/state.env" "" "" 0)"
case "$M3" in *"propón al usuario limpiar el contexto"*) echo "ok   planner_msg: limpieza al cerrar paso";; *) echo "FAIL planner_msg limpieza: $M3"; FAIL=1;; esac

# MCP para cualquier agente: archivo mcpServers, overrides de Codex, placeholder {mcp} en custom, --mcp-config en claude
cat > "$KIT/config.json" <<'J'
{ "defaults": { "mcp": [] }, "mcpServers": {
    "ctx": { "type": "http", "url": "http://ctx" },
    "pw": { "command": "npx", "args": ["-y", "@playwright/mcp@latest"], "env": { "A": "1" } } },
  "roles": {
    "cl": { "agent": "claude", "mcp": ["ctx"] },
    "cla": { "agent": "claude", "mcp": "all" },
    "cx": { "agent": "codex", "mcp": ["ctx", "pw", "nope"] },
    "cu": { "agent": "custom", "command": "run --mcp {mcp}", "mcp": ["pw"] },
    "cua": { "agent": "custom", "command": "run --mcp {mcp}", "mcp": "all" } } }
J
C="$KIT/config.json"
check "mcp_file filtra por nombre" "$(mcp_file "$C" cx | jq -c '.mcpServers | keys')" '["ctx","pw"]'
check "mcp_file vacío" "$(mcp_file "$C" cua | jq -c .)" '{"mcpServers":{}}'
mcp_file "$C" cx > "$TMP/mcp.json"
check "codex overrides" "$(codex_mcp_overrides "$TMP/mcp.json" | tr '\n' '|')" 'mcp_servers.ctx.url="http://ctx"|mcp_servers.pw.command="npx"|mcp_servers.pw.args=["-y","@playwright/mcp@latest"]|mcp_servers.pw.env={A = "1"}|'
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$TMP/fakebin/codex"; chmod +x "$TMP/fakebin/codex"
cp "$TMP/fakebin/codex" "$TMP/fakebin/claude"
printf '#!/bin/sh\n[ "$1" = -lc ] && { echo "$2"; exit 0; }\nexec /bin/bash "$@"\n' > "$TMP/fakebin/bash"; chmod +x "$TMP/fakebin/bash"   # bash -lc → imprime el comando
run_agent() { (cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/agent.sh" "$@" 2>&1); }
OUT="$(run_agent cx | tr '\n' ' ')"
case "$OUT" in *'-c mcp_servers.ctx.url="http://ctx" -c mcp_servers.pw.command="npx" -c mcp_servers.pw.args=["-y","@playwright/mcp@latest"] -c mcp_servers.pw.env={A = "1"} '*) echo "ok   agent.sh codex: -c por servidor";; *) echo "FAIL agent.sh codex: $OUT"; FAIL=1;; esac
OUT="$(run_agent cl | tr '\n' ' ')"
case "$OUT" in *"--strict-mcp-config --mcp-config "*) echo "ok   agent.sh claude: --mcp-config";; *) echo "FAIL agent.sh claude: $OUT"; FAIL=1;; esac
F="$(run_agent cl | grep -A1 -- '--mcp-config' | tail -1)"; check "agent.sh claude: contenido del archivo" "$(jq -c '.mcpServers | keys' "$F")" '["ctx"]'
OUT="$(run_agent cla | tr '\n' ' ')"
case "$OUT" in *"--mcp-config"*) echo "FAIL agent.sh claude all pasa mcp-config"; FAIL=1;; *) echo "ok   agent.sh claude: all no restringe";; esac
OUT="$(run_agent cu)"; F="${OUT#run --mcp }"
check "agent.sh custom: {mcp} apunta a un archivo con los servidores" "$(jq -c '.mcpServers | keys' "$F" 2>/dev/null)" '["pw"]'
check "agent.sh custom: {mcp} vacío con all" "$(run_agent cua)" "run --mcp "
rm -f "$TMP/fakebin/codex" "$TMP/fakebin/claude"

# Placeholders de mcpServers, nombre de proyecto y estado del navegador
cat > "$KIT/config.json" <<'J'
{ "defaults": { "mcp": [] }, "mcpServers": {
    "pw": { "command": "npx", "args": ["-y", "@playwright/mcp@latest", "--headless", "--storage-state", "{browserState}", "--output-dir", "{worktree}/{evidenceDir}"], "env": { "P": "{project}", "K": "{kit}" } },
    "h": { "type": "http", "url": "http://{home}/x" } },
  "roles": { "vt": { "agent": "custom", "command": "run {mcp}", "mcp": ["pw", "h"], "params": { "evidenceDir": "ev" } },
             "other": { "agent": "custom", "command": "run {mcp}", "mcp": ["pw"] } } }
J
C="$KIT/config.json"
check "project_name en un worktree" "$(project_name "$PROJ")" "proj"
mkdir -p "$TMP/plain"; check "project_name sin git" "$(project_name "$TMP/plain")" "plain"
( role_context "$C" vt "$PROJ"
  check "role_context: worktree" "$ORCA_ROLES_WORKTREE" "$(cd "$PROJ" && pwd)"
  check "role_context: evidenceDir del rol" "$ORCA_ROLES_EVIDENCE_DIR" "ev"
  check "role_context: estado del navegador por proyecto" "$ORCA_ROLES_BROWSER_STATE" "$KIT/browser/proj.json"
  A="$(mcp_file "$C" vt | jq -c '.mcpServers.pw.args')"
  check "mcp_file expande placeholders en args" "$A" "[\"-y\",\"@playwright/mcp@latest\",\"--headless\",\"--storage-state\",\"$KIT/browser/proj.json\",\"--output-dir\",\"$(cd "$PROJ" && pwd)/ev\"]"
  check "mcp_file expande en env y url" "$(mcp_file "$C" vt | jq -r '.mcpServers.pw.env.P + " " + .mcpServers.pw.env.K + " " + .mcpServers.h.url')" "proj $KIT http://$HOME/x"
  [ "$FAIL" = 0 ] ) || FAIL=1
( role_context "$C" other "$PROJ"; check "role_context: evidenceDir por defecto" "$ORCA_ROLES_EVIDENCE_DIR" "qa-evidence"; [ "$FAIL" = 0 ] ) || FAIL=1
OUT="$(cd "$PROJ" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/agent.sh" vt 2>&1)"; F="${OUT#run }"
check "agent.sh crea el estado de navegador vacío" "$(cat "$TMP/home/.orca-roles/browser/proj.json" 2>/dev/null)" '{"cookies":[],"origins":[]}'
check "agent.sh: archivo MCP con placeholders expandidos" "$(jq -r '.mcpServers.pw.args[4]' "$F" 2>/dev/null)" "$TMP/home/.orca-roles/browser/proj.json"
echo '{"cookies":[{"n":1}],"origins":[]}' > "$KIT/browser/proj.json"
( role_context "$C" vt "$PROJ"; ensure_browser_state "$ORCA_ROLES_BROWSER_STATE"; check "ensure_browser_state no pisa una sesión existente" "$(jq -c '.cookies | length' "$KIT/browser/proj.json")" "1"; [ "$FAIL" = 0 ] ) || FAIL=1
grep -q -- '--headless' "$ROOT/config.default.json" && grep -q '{browserState}' "$ROOT/config.default.json" && grep -q '{worktree}/{evidenceDir}' "$ROOT/config.default.json" && echo "ok   config.default: playwright headless con sesión y evidencias" || { echo "FAIL config.default playwright"; FAIL=1; }
for sec in '^## Tu navegador' 'browser-login.sh' 'browser_evaluate'; do grep -q "$sec" "$ROOT/prompts/visual-tester.md" || { echo "FAIL visual-tester.md sin $sec"; FAIL=1; }; done
grep -q 'browser-login.sh' "$ROOT/prompts/planner.md" || { echo "FAIL planner.md sin browser-login"; FAIL=1; }
grep -q 'orca-<servicio>.pid' "$ROOT/prompts/deployer.md" || { echo "FAIL deployer.md sin servicios"; FAIL=1; }
echo "ok   prompts de prueba visual"

# agent.sh custom: placeholders y extraArgs (se sustituye bash por un eco)
cat > "$KIT/config.json" <<J
{ "defaults": {}, "mcpServers": {}, "roles": { "x": { "agent": "custom", "command": "run --m {model} --p {prompts} --f {prompt}", "model": "a b", "extraArgs": ["--k", "v w"] } } }
J
printf '#!/bin/sh\n[ "$1" = -lc ] && { echo "$2"; exit 0; }\nexec /bin/bash "$@"\n' > "$TMP/fakebin/bash"; chmod +x "$TMP/fakebin/bash"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$KIT/bin/agent.sh" x)"
check "custom: comando con placeholders y extraArgs" "$OUT" "run --m a\\ b --p $TMP/home/.orca-roles/prompts --f $TMP/home/.orca-roles/prompts/x.md --k v\\ w"

# Clave de Jira: la de Orca (linkedWorkItem) manda; sin enlace, solo de la rama y en mayúsculas al inicio de un segmento
check "jira: jiraIdentifier de Orca" "$(jira_key feature/otra-cosa devgd-220 "")" "DEVGD-220"
check "jira: URL si no hay identificador" "$(jira_key feature/ABC-1 "" "https://jira.empresa.com/browse/devgd-7")" "DEVGD-7"
check "jira: rama con clave" "$(jira_key DEVGD-220-nueva-api "" "")" "DEVGD-220"
check "jira: clave tras prefijo" "$(jira_key feature/DEVGD-220 "" "")" "DEVGD-220"
check "jira: fix-123 no es un ticket" "$(jira_key feature/fix-123 "" "")" ""
check "jira: release-1.4 no es un ticket" "$(jira_key release-1.4 "" "")" ""
check "jira: rama sin clave" "$(jira_key main "" "")" ""
JSON='{"worktree":{"branch":"x","linkedWorkItem":{"provider":"jira","type":"issue","number":0,"title":"t","url":"https://jira.empresa.com/browse/DEVGD-9","jiraIdentifier":"DEVGD-9"}}}'
check "jira: jiraIdentifier en orca worktree show" "$(printf '%s' "$JSON" | jq -r '[.. | objects | select(.provider? == "jira") | .jiraIdentifier // empty] | first // empty')" "DEVGD-9"

# Título de la sesión extra del composer: rama exacta o empieza por la clave
RE="$(composer_title_regex DEVGD-220 api)"
t_match() { jq -nr --arg re "$RE" --arg t "$1" '$t | test($re; "i")'; }
check "composer: clave exacta" "$(t_match DEVGD-220)" "true"
check "composer: clave con resumen" "$(t_match 'devgd-220: nueva api')" "true"
check "composer: otra clave más larga" "$(t_match DEVGD-2201)" "false"
check "composer: rama exacta" "$(t_match api)" "true"
check "composer: rama como subcadena" "$(t_match 'api tests')" "false"
check "composer: rama con caracteres de regex" "$(composer_title_regex "" feat/a.b)" '^(feat/a\.b)$'
check "composer: sin clave ni rama" "$(composer_title_regex "" "")" ""

# .orca-roles.json sin commitear en el checkout principal se aplica también en sus worktrees
MAIN="$TMP/main"; mkdir -p "$MAIN"; git -C "$MAIN" init -q
git -C "$MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$TMP/wt" -b wt-rama 2>/dev/null
echo '{ "settings": { "jiraHandoff": false } }' > "$MAIN/.orca-roles.json"
check "config de proyecto desde el checkout principal" "$(merged_config "$TMP/wt" | jq -r '.settings.jiraHandoff')" "false"
echo '{ "settings": { "jiraHandoff": true } }' > "$TMP/wt/.orca-roles.json"
check "config de proyecto: la del worktree tiene prioridad" "$(merged_config "$TMP/wt" | jq -r '.settings.jiraHandoff')" "true"

# Archivo MCP en la carpeta git del worktree (no se acumulan temporales)
check "agent.sh: archivo MCP en la carpeta git" "$F" "$(cd "$PROJ/.git" && pwd)/orca-roles-mcp-vt.json"

# Listas vacías (bash 3.2 de macOS falla con "${A[@]}" vacío y set -u)
cat > "$KIT/config.json" <<'J'
{ "defaults": {}, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "cx": { "agent": "codex", "mcp": "all" } } }
J
printf '#!/bin/sh\necho "codex:$#"\n' > "$TMP/fakebin/codex"; chmod +x "$TMP/fakebin/codex"
check "agent.sh codex sin argumentos" "$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$KIT/bin/agent.sh" cx 2>&1)" "codex:0"
printf 'PLANNER=t1\n' > "$TMP/state.env"
check "clean.sh --all sin workers" "$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$KIT/config.json" "$KIT/bin/clean.sh" --all 2>&1)" "No hay workers que limpiar en este workspace."

# CLI de Orca con otro nombre (WSL: ORCA_CLI_COMMAND=orca-ide): envoltorio 'orca' en $KIT/shim
mkdir -p "$TMP/cli"; printf '#!/bin/sh\necho "orca-ide:$*"\n' > "$TMP/cli/orca-ide"; chmod +x "$TMP/cli/orca-ide"
check "shim: 'orca' llama a ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide bash -c '. "$KIT/bin/lib.sh"; orca terminal list')" "orca-ide:terminal list"
rm -f "$KIT/shim/orca"
check "shim: no se crea sin ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND='' bash -c '. "$KIT/bin/lib.sh"; command -v orca || echo ninguno')" "ninguno"
check "shim: no se crea si 'orca' ya existe" "$(PATH="$TMP/fakebin:$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide bash -c 'printf "#!/bin/sh\n" > "$0/orca"; chmod +x "$0/orca"; . "$KIT/bin/lib.sh"; command -v orca' "$TMP/fakebin")" "$TMP/fakebin/orca"
rm -f "$TMP/fakebin/orca"

# roles-yaml: orca.yaml local, ignorado y listado en .worktreeinclude, sin nada que commitear
Y="$TMP/ymain"; mkdir -p "$Y"; git -C "$Y" init -q; git -C "$Y" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$Y" worktree add -q "$TMP/ywt" -b yrama 2>/dev/null
yaml() { (cd "$1" && shift && "$ROOT/bin/orca-yaml.sh" "$@" 2>&1); }
try yaml "$TMP/ywt"; check "roles-yaml: termina bien desde un worktree" "$RC" "0"
check "roles-yaml: orca.yaml en el checkout principal" "$(grep -c 'orca-roles/bin/launch.sh' "$Y/orca.yaml")" "1"
check "roles-yaml: listado en .worktreeinclude" "$(grep -cx orca.yaml "$Y/.worktreeinclude")" "1"
check "roles-yaml: ignorado por git" "$(git -C "$Y" check-ignore orca.yaml .worktreeinclude | tr '\n' ' ')" "orca.yaml .worktreeinclude "
check "roles-yaml: nada que commitear" "$(git -C "$Y" status --porcelain)" ""
ANTES="$(cat "$Y/orca.yaml" "$Y/.worktreeinclude" "$Y/.git/info/exclude")"
yaml "$TMP/ywt" >/dev/null; check "roles-yaml: idempotente" "$(cat "$Y/orca.yaml" "$Y/.worktreeinclude" "$Y/.git/info/exclude")" "$ANTES"
check "roles-yaml: sin líneas repetidas en exclude" "$(grep -cx orca.yaml "$Y/.git/info/exclude")" "1"
try yaml "$Y" --remove; check "roles-yaml --remove" "$RC:$(ls -A "$Y" | tr '\n' ' '):$(grep -cx 'orca.yaml\|.worktreeinclude' "$Y/.git/info/exclude" || true)" "0:.git :0"
printf 'scripts:\n  setup: npm i\n' > "$Y/orca.yaml"
try yaml "$Y"; check "roles-yaml: no toca un orca.yaml ajeno" "$RC:$(cat "$Y/orca.yaml" | tr '\n' ' ')" "1:scripts:   setup: npm i "
git -C "$Y" add orca.yaml; git -C "$Y" -c user.name=t -c user.email=t@t commit -q -m yaml
try yaml "$Y"; check "roles-yaml: no toca un orca.yaml commiteado" "$RC" "1"; case "$OUT" in *commiteado*) echo "ok   roles-yaml explica el orca.yaml commiteado";; *) echo "FAIL roles-yaml: $OUT"; FAIL=1;; esac

# Excepciones de launch.sh (setup script del proyecto): --only, --enable, --disable, --set, guardadas por worktree
check "overrides: listas y --set tipado" "$(overrides_from_args --only planner,dev --disable 'x, y' --set roles.dev.model=m1 --set=settings.jiraHandoff=false --set roles.t.params.n=5)" \
  '{"only":["planner","dev"],"enable":[],"disable":["x","y"],"set":[{"path":["roles","dev","model"],"value":"m1"},{"path":["settings","jiraHandoff"],"value":false},{"path":["roles","t","params","n"],"value":5}]}'
try overrides_from_args --nope 2>/dev/null; check "overrides: opción desconocida" "$RC" "1"
try overrides_from_args --set sinvalor 2>/dev/null; check "overrides: --set sin =" "$RC" "1"
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev", "model": "m-dev" },
             "tester": { "title": "Tester", "enabled": false }, "deployer": { "title": "Deployer" } } }
J
overrides_from_args --only dev --enable tester --set roles.dev.model=m2 > "$TMP/ovr.json"
check "apply_overrides: --only deja planner y dev, --enable suma tester" "$(apply_overrides "$KIT/config.json" "$TMP/ovr.json" > "$TMP/c.json"; enabled_roles "$TMP/c.json" | tr '\n' ' ')" "planner dev tester "
check "apply_overrides: --set" "$(jq -r '.roles.dev.model' "$TMP/c.json")" "m2"
overrides_from_args --disable planner,nadie > "$TMP/ovr.json"
check "check_overrides: rol desconocido y planner" "$(check_overrides "$KIT/config.json" "$TMP/ovr.json" | cut -c1-40 | tr '\n' '|')" "ERROR: roles desconocidos: nadie. Dispon|ERROR: el planner no se puede desactivar|"
# launch.sh de punta a punta con un 'orca' simulado (cada pestaña se llama h-<título>; ninguna sigue viva al relanzar)
L="$TMP/lproj"; mkdir -p "$L" "$TMP/lbin"; git -C "$L" init -q
cat > "$TMP/lbin/orca" <<'EOS'
#!/bin/sh
case "$1 $2" in
  "terminal create") while [ $# -gt 0 ]; do [ "$1" = --title ] && t="$2"; shift; done; echo "{\"handle\":\"h-$t\"}";;
  "terminal show") exit 1;;
esac
exit 0
EOS
chmod +x "$TMP/lbin/orca"
launch() { (cd "$L" && HOME="$TMP/home" PATH="$TMP/lbin:$PATH" "$TMP/home/.orca-roles/bin/launch.sh" "$@" 2>&1); }
handles() { cut -d= -f1 "$L/.git/orca-roles.env" | tr '\n' ' '; }
try launch --disable deployer --set roles.dev.model=m3; check "launch: --disable" "$RC:$(handles)" "0:PLANNER DEV "
check "launch: --set en la config efectiva" "$(jq -r '.roles.dev.model' "$L/.git/orca-roles.config.json")" "m3"
try launch; check "launch: retoma con las excepciones guardadas" "$RC:$(handles)" "0:PLANNER DEV "
case "$OUT" in *"excepciones guardadas"*) echo "ok   launch: avisa de las excepciones guardadas";; *) echo "FAIL launch guardadas: $OUT"; FAIL=1;; esac
try launch --reset; check "launch: --reset vuelve a la configuración" "$RC:$(handles)" "0:PLANNER DEV DEPLOYER "
try launch --only dev; check "launch: --only" "$RC:$(handles)" "0:PLANNER DEV "
try launch --enable nadie; check "launch: rol desconocido falla" "$RC" "1"
check "launch: un error no pisa las excepciones guardadas" "$(jq -c .only "$L/.git/orca-roles.overrides.json")" '["dev"]'
sleep 1   # deja terminar los kickoff en segundo plano antes de borrar el directorio temporal

[ "$FAIL" = 0 ] && echo "TODO OK" || { echo "HAY FALLOS"; exit 1; }
