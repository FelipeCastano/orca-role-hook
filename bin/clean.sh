#!/usr/bin/env bash
# Limpia el contexto de uno o varios workers: abre una conversación nueva en su agente y le reenvía su rol.
# Uso (desde el worktree):  clean.sh <rol|título|handle> [...]   |   clean.sh --all   |   clean.sh --msg <rol>  (solo imprime el mensaje de rol)
# Lo ejecuta el Planner tras la confirmación del usuario. Nunca limpia al Planner ni a un worker con tarea en vuelo (eso lo garantiza el Planner).
set -uo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
STATE="${ORCA_ROLES_STATE:-$GITDIR/orca-roles.env}"; CFG="${ORCA_ROLES_CONFIG:-$GITDIR/orca-roles.config.json}"
[ -f "$STATE" ] && [ -f "$CFG" ] || { echo "No encuentro $STATE o $CFG: ejecuta esto desde el worktree donde se abrieron los roles." >&2; exit 1; }
[ $# -gt 0 ] || { sed -n 2,3p "$0" >&2; exit 1; }
# shellcheck source=/dev/null
. "$STATE"
TIMEOUT_MS=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))
IDS="$(cut -d= -f1 "$STATE" | tr 'A-Z_' 'a-z-')"
lower() { tr 'A-Z' 'a-z'; }

resolve() {  # <rol|título|handle> → id de rol
  local x="$1" id v
  for id in $IDS; do
    v="$(var_of "$id")"
    if [ "$x" = "$id" ] || [ "$(echo "$x" | lower)" = "$(title_of "$CFG" "$id" | lower)" ] || [ "$x" = "${!v}" ]; then echo "$id"; return; fi
  done
}

if [ "$1" = --msg ]; then id="$(resolve "${2:-}")"; [ -n "$id" ] || { echo "Rol desconocido: ${2:-}" >&2; exit 1; }; worker_msg "$CFG" "$id"; echo; exit 0; fi
TARGETS=()
if [ "$1" = --all ]; then
  for id in $IDS; do [ "$id" = planner ] || TARGETS+=("$id"); done
else
  for x in "$@"; do id="$(resolve "$x")"; [ -n "$id" ] || { echo "No hay ningún worker '$x' en este workspace. Roles: $(echo $IDS)" >&2; exit 1; }; TARGETS+=("$id"); done
fi

[ ${#TARGETS[@]} -gt 0 ] || { echo "No hay workers que limpiar en este workspace."; exit 0; }
RC=0
for id in "${TARGETS[@]}"; do
  t="$(title_of "$CFG" "$id")"
  [ "$id" = planner ] && { echo "$t: el Planner no se limpia a sí mismo."; RC=1; continue; }
  v="$(var_of "$id")"; h="${!v}"
  orca terminal show --terminal "$h" --json >/dev/null 2>&1 || { echo "$t: su pestaña ($h) no responde."; RC=1; continue; }
  cmd="$(clear_command "$CFG" "$id")"
  [ -n "$cmd" ] || { echo "$t: su agente no tiene comando de limpieza; define 'clearCommand' en su rol de config.json."; RC=1; continue; }
  orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1; sleep 1
  orca terminal send --terminal "$h" --text "$cmd" --enter --json >/dev/null || { echo "$t: no pude enviar $cmd."; RC=1; continue; }
  orca terminal wait --terminal "$h" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
  if orca terminal send --terminal "$h" --text "$(worker_msg "$CFG" "$id")" --enter --json >/dev/null; then
    echo "$t: contexto limpiado ($cmd) y rol reenviado."
  else
    echo "$t: contexto limpiado, pero no pude reenviar el rol. Reenvíalo con: orca terminal send --terminal $h --text \"\$($KIT/bin/clean.sh --msg $id)\" --enter"; RC=1
  fi
done
exit $RC
