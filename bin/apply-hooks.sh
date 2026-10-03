#!/usr/bin/env bash
# Explica cómo registrar launch.sh como setup script de cada proyecto. El CLI de Orca no tiene ningún comando para
# los setup scripts (ver decisions.md §14), así que el instalador no puede hacerlo solo: hay dos vías.
set -euo pipefail
echo
echo "Falta registrar el kit en cada proyecto (una vez por proyecto). Elige una vía:"
echo "  a) En Orca: Settings → Repository → <proyecto> → Setup script, pega:"
echo "       \$HOME/.orca-roles/bin/launch.sh"
echo "  b) En una terminal dentro del proyecto: roles-yaml"
echo "     (crea un orca.yaml local, ignorado por git: no hay nada que commitear)"
