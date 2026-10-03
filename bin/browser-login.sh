#!/usr/bin/env bash
# Inicia sesión UNA vez en la aplicación con un navegador visible y guarda la sesión (cookies y localStorage)
# para que el Visual-Tester la reutilice en headless.
# Uso (desde el worktree o el repo del proyecto):  browser-login.sh <url> [nombre-del-proyecto]
# La sesión se guarda en ~/.orca-roles/browser/<proyecto>.json (por defecto, el nombre de la carpeta del repo principal).
set -euo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
URL="${1:-}"; [ -n "$URL" ] || { sed -n 2,5p "$0" >&2; exit 1; }
PROJ="${2:-$(project_name .)}"
STATE="$KIT/browser/$PROJ.json"; mkdir -p "$KIT/browser"
command -v npx >/dev/null || { echo "ERROR: falta npx (Node)." >&2; exit 1; }
echo "Proyecto: $PROJ"
echo "Se abrirá un navegador en $URL. Inicia sesión (incluido MFA) y, cuando veas la aplicación cargada, CIERRA la ventana del navegador."
echo "La sesión se guardará en $STATE"
npx -y playwright open --save-storage="$STATE" "$URL" || {
  echo "No pude abrir el navegador. Si es la primera vez, instala Chromium: npx playwright install chromium" >&2; exit 1; }
if jq -e '((.cookies // []) | length) + ((.origins // []) | length) > 0' "$STATE" >/dev/null 2>&1; then
  echo "Sesión guardada: $(jq -r '"\((.cookies // []) | length) cookies, \((.origins // []) | length) orígenes con localStorage"' "$STATE")."
  echo "El Visual-Tester la usará en el próximo arranque de sus pestañas (o tras limpiarlo con clean.sh)."
else
  echo "Aviso: la sesión guardada está vacía. ¿Cerraste el navegador antes de terminar el login?" >&2; exit 1
fi
