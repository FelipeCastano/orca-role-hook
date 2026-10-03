#!/usr/bin/env bash
# Registra el kit como setup script de un proyecto sin commitear nada (comando roles-yaml).
# Crea orca.yaml en la raíz del checkout principal, lo ignora en .git/info/exclude (local, no toca .gitignore) y lo lista
# en .worktreeinclude, también ignorado: Orca copia a cada worktree nuevo los archivos ignorados que ahí aparecen,
# antes de buscar su setup script, así que el orca.yaml llega al worktree y Orca ejecuta launch.sh.
# Uso (desde cualquier carpeta del proyecto):  roles-yaml   |   roles-yaml --remove
set -euo pipefail
MARK="# Generado por orca-roles (roles-yaml)"
case "${1:-}" in -h|--help) sed -n 2,6p "$0"; exit 0;; ""|--remove) ;; *) echo "Opción desconocida: $1" >&2; exit 1;; esac

COMMON="$(git rev-parse --git-common-dir 2>/dev/null)" || { echo "ERROR: ejecuta esto dentro del repo del proyecto." >&2; exit 1; }
COMMON="$(cd "$COMMON" && pwd)"
[ "$(basename "$COMMON")" = .git ] || { echo "ERROR: no encuentro el checkout principal del repo ($COMMON)." >&2; exit 1; }
ROOT="$(dirname "$COMMON")"; EXCLUDE="$COMMON/info/exclude"; YAML="$ROOT/orca.yaml"; INCLUDE="$ROOT/.worktreeinclude"

tracked()     { git -C "$ROOT" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; }
has_line()    { [ -f "$2" ] && grep -qxF "$1" "$2"; }
remove_line() { [ -f "$2" ] || return 0; local t; t="$(mktemp)"; grep -vxF "$1" "$2" > "$t" || true; cat "$t" > "$2"; rm -f "$t"; }
ours()        { [ -f "$YAML" ] && grep -qxF "$MARK" "$YAML"; }

if [ "${1:-}" = --remove ]; then
  if ours; then rm -f "$YAML"; echo "Borrado $YAML"; fi
  if ! tracked .worktreeinclude; then
    remove_line orca.yaml "$INCLUDE"
    # Si solo quedaba nuestro comentario, el archivo era nuestro: se borra
    if [ -f "$INCLUDE" ] && ! grep -qvE "^(# Generado por orca-roles.*)?$" "$INCLUDE"; then rm -f "$INCLUDE"; echo "Borrado $INCLUDE"; remove_line .worktreeinclude "$EXCLUDE"; fi
  fi
  remove_line orca.yaml "$EXCLUDE"
  echo "Listo: los worktrees nuevos de este proyecto ya no ejecutarán el kit por orca.yaml."
  exit 0
fi

# Nunca se modifica nada commiteado: eso dejaría cambios pendientes en el proyecto
if tracked orca.yaml; then
  echo "ERROR: este proyecto ya tiene un orca.yaml commiteado. Añade a su 'scripts: setup:' la línea" >&2
  echo "  \$HOME/.orca-roles/bin/launch.sh" >&2
  echo "o configúralo en Settings → Repository → Setup script." >&2; exit 1
fi
if [ -f "$YAML" ] && ! ours; then
  echo "ERROR: ya hay un orca.yaml sin commitear que no generó el kit ($YAML); no lo toco." >&2
  echo "Añade a su 'scripts: setup:' la línea \$HOME/.orca-roles/bin/launch.sh, o bórralo y repite." >&2; exit 1
fi
if tracked .worktreeinclude && ! has_line orca.yaml "$INCLUDE"; then
  echo "ERROR: este proyecto tiene un .worktreeinclude commiteado sin 'orca.yaml'. Añade esa línea (y commitéala)," >&2
  echo "o configura el setup script en Settings → Repository → Setup script." >&2; exit 1
fi

if ! ours; then
  cat > "$YAML" <<EOF
$MARK
# Local: ignorado en .git/info/exclude y copiado a cada worktree nuevo por .worktreeinclude. Para quitarlo: roles-yaml --remove
scripts:
  setup: |
    \$HOME/.orca-roles/bin/launch.sh
EOF
  echo "Creado $YAML"
fi
mkdir -p "$COMMON/info"; touch "$EXCLUDE"
has_line orca.yaml "$EXCLUDE" || echo orca.yaml >> "$EXCLUDE"
if ! tracked .worktreeinclude; then
  [ -f "$INCLUDE" ] || echo "# Generado por orca-roles: archivos ignorados que Orca copia a cada worktree nuevo" > "$INCLUDE"
  has_line orca.yaml "$INCLUDE" || echo orca.yaml >> "$INCLUDE"
  has_line .worktreeinclude "$EXCLUDE" || echo .worktreeinclude >> "$EXCLUDE"
fi

# Comprobación: Orca solo copia lo que git considera ignorado
git -C "$ROOT" check-ignore -q orca.yaml || { echo "ERROR: git no considera ignorado orca.yaml; Orca no lo copiaría." >&2; exit 1; }
echo "Listo: los worktrees nuevos de $(basename "$ROOT") ejecutarán el kit. No hay nada que commitear."
echo "Nota: si en Settings → Repository este proyecto ya tiene un setup script propio, Orca usa ese e ignora orca.yaml."
