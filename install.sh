#!/usr/bin/env bash
# Instalador de orca-roles.
#
# Desde GitHub (sin clonar):
#   curl -fsSL https://raw.githubusercontent.com/FelipeCastano/orca-role-hook/main/install.sh | bash   (solo si el repo es público)
# Desde un clon local:
#   ./install.sh
# Toda la configuración (roles activos, modelos, agentes, MCP, parámetros) vive en ~/.orca-roles/config.json
set -euo pipefail

REPO="${ORCA_ROLES_REPO:-FelipeCastano/orca-role-hook}"
BRANCH="${ORCA_ROLES_BRANCH:-main}"
KIT="$HOME/.orca-roles"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n 2,8p "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0;;
    *) echo "Opción desconocida: $1 (los roles se activan en $KIT/config.json)" >&2; exit 1;;
  esac
done

# Requisitos: jq es imprescindible (todo el kit lee la configuración con él); el resto puede instalarse después.
command -v jq >/dev/null || { echo "ERROR: falta 'jq' (macOS: brew install jq; Ubuntu: sudo apt install jq). Sin él no se puede instalar ni ejecutar el kit." >&2; exit 1; }
command -v orca >/dev/null || command -v "${ORCA_CLI_COMMAND:-orca}" >/dev/null || echo "Aviso: no encuentro el CLI de Orca en el PATH. En Windows (WSL), ejecuta el instalador desde una terminal de Orca (ver README → Windows con WSL2)."
command -v claude >/dev/null || echo "Aviso: no encuentro 'claude' en el PATH (ver README → Requisitos)."
if command -v claude >/dev/null && ! claude --help 2>/dev/null | grep -A4 'permission-mode <mode>' | grep -q '"auto"'; then
  echo "Aviso: tu Claude Code ($(claude --version 2>/dev/null | head -1)) no ofrece --permission-mode auto. Actualízalo o cambia 'permissionMode' en config.json."
fi

# Origen: el clon local si el script se ejecuta desde él; si no (curl | bash), descarga el repo.
SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -z "$SRC" ] || [ ! -d "$SRC/bin" ]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  echo "Descargando $REPO ($BRANCH)..."
  if ! curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$TMP" 2>/dev/null; then
    echo "No pude descargar $REPO. Si el repo es privado, clónalo y ejecuta ./install.sh desde el clon." >&2; exit 1
  fi
  SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
fi

# Copia del kit (tu config.json y tus roles en ~/.orca-roles/roles/ se conservan entre actualizaciones)
mkdir -p "$KIT"
rm -rf "${KIT:?}/bin" "${KIT:?}/prompts" "${KIT:?}/mcp"   # se regeneran; config.json y roles/ no se tocan
cp -R "$SRC/bin" "$SRC/prompts" "$SRC/README.md" "$SRC/config.default.json" "$KIT/"
chmod +x "$KIT/bin/"*.sh
rm -f "$KIT/config.env"   # formato antiguo
. "$KIT/bin/lib.sh"
CONF="$KIT/config.json"
if [ ! -f "$CONF" ]; then
  cp "$KIT/config.default.json" "$CONF"; echo "Creada tu configuración: $CONF"
else
  # Añade roles o claves nuevas de la versión instalada sin pisar lo que ya tienes (ni el orden de tus roles)
  TMPC="$(mktemp)"
  upgrade_config "$KIT/config.default.json" "$CONF" > "$TMPC"
  mv "$TMPC" "$CONF"
fi
jq empty "$CONF" || { echo "ERROR: $CONF no es JSON válido" >&2; exit 1; }

# Alias 'roles', 'nuevo-rol' y 'roles-yaml' (una sola vez)
# zsh → ~/.zshrc; bash → ~/.bashrc (en macOS, ~/.bash_profile, que es lo que lee Terminal); otro shell → ~/.profile
case "$(basename "${SHELL:-}")" in
  zsh) RC="$HOME/.zshrc";;
  bash) if [ "$(uname -s)" = Darwin ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi;;
  *) RC="$HOME/.profile";;
esac
grep -q 'alias roles=' "$RC" 2>/dev/null || echo 'alias roles="$HOME/.orca-roles/bin/launch.sh"' >> "$RC"
grep -q 'alias nuevo-rol=' "$RC" 2>/dev/null || echo 'alias nuevo-rol="$HOME/.orca-roles/bin/new-role.sh"' >> "$RC"
grep -q 'alias roles-yaml=' "$RC" 2>/dev/null || echo 'alias roles-yaml="$HOME/.orca-roles/bin/orca-yaml.sh"' >> "$RC"

echo
echo "Instalado en $KIT"
echo "Configuración: $CONF"
echo "Disponibles: $(jq -r '.roles | keys_unsorted | join(" ")' "$CONF")"
echo "Activos:     $(enabled_roles "$CONF" | tr '\n' ' ')"
echo "Para activar o desactivar roles, edita \"enabled\" en $CONF."
"$KIT/bin/apply-hooks.sh"
echo "Abre una terminal nueva (o 'source $RC') para usar los comandos 'roles', 'nuevo-rol' y 'roles-yaml'."
