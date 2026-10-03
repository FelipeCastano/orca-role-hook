#!/usr/bin/env bash
# Abre las pestañas de los roles activos en el worktree y lanza en segundo plano su arranque.
# Uso: launch.sh [id:<worktree>] [excepciones]
#   --only a,b       solo esos roles (el planner va siempre)
#   --enable a,b     activa roles desactivados en la configuración
#   --disable a,b    desactiva roles
#   --set ruta=valor cualquier clave de la configuración (p. ej. roles.dev.model=claude-opus-5-5, settings.jiraHandoff=false)
#   --reset          olvida las excepciones guardadas de este worktree
# Las excepciones van en la línea del setup script del proyecto y se aplican encima de config.json y .orca-roles.json.
# Se guardan por worktree, así que 'roles' sin opciones las vuelve a aplicar al retomar.
set -uo pipefail
case "${1:-}" in -h|--help) sed -n 2,10p "$0"; exit 0;; esac
command -v jq >/dev/null || { echo "ERROR: falta 'jq' (macOS: brew install jq; Ubuntu: sudo apt install jq); orca-roles no puede leer su configuración sin él." >&2; exit 1; }
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
command -v orca >/dev/null || { echo "ERROR: no encuentro el CLI de Orca ('orca' ni \$ORCA_CLI_COMMAND). Ejecuta esto desde una terminal de Orca." >&2; exit 1; }
WT=""; RESET=0; FLAGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) RESET=1;;
    --only|--enable|--disable|--set) FLAGS+=("$1" "${2:-}"); shift;;
    -*) FLAGS+=("$1");;
    *) WT="$1";;
  esac
  shift
done
WT="${WT:-${ORCA_WORKTREE_ID:+id:$ORCA_WORKTREE_ID}}"; WT="${WT:-active}"
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .)"; GITDIR="$(cd "$GITDIR" && pwd)"
OVR="$GITDIR/orca-roles.overrides.json"  # excepciones de este worktree
STATE="$GITDIR/orca-roles.env"
CFG="$GITDIR/orca-roles.config.json"     # copia de la config efectiva para este worktree
LOG="$GITDIR/orca-roles-launch.log"
exec > >(tee -a "$LOG") 2>&1
echo "== $(date '+%F %T') launch.sh en $WT"

merged_config . > "$CFG" || { echo "ERROR: configuración inválida (revisa ~/.orca-roles/config.json y .orca-roles.json)"; exit 1; }
[ "$RESET" = 1 ] && rm -f "$OVR" && echo "Excepciones de este worktree olvidadas."
if [ ${#FLAGS[@]} -gt 0 ]; then
  NEWOVR="$(overrides_from_args "${FLAGS[@]}")" || exit 1
  printf '%s\n' "$NEWOVR" > "$OVR.tmp"
  ERR="$(check_overrides "$CFG" "$OVR.tmp")"
  [ -z "$ERR" ] || { rm -f "$OVR.tmp"; echo "$ERR"; exit 1; }
  mv "$OVR.tmp" "$OVR"
elif [ -f "$OVR" ]; then
  echo "Aplicando las excepciones guardadas de este worktree ($OVR)."
fi
if [ -f "$OVR" ]; then
  echo "Excepciones: $(jq -c '{only, enable, disable, set: [.set[] | "\(.path | join(".")): \(.value | tojson)"]} | with_entries(select(.value | length > 0))' "$OVR")"
  apply_overrides "$CFG" "$OVR" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG" || { echo "ERROR: no pude aplicar las excepciones de $OVR"; exit 1; }
fi

alive()     { [ -n "${1:-}" ] && orca terminal show --terminal "$1" --json >/dev/null 2>&1; }
handle_of() { jq -r '[.. | .handle? // empty] | first // empty'; }

WAIT="$(setting "$CFG" launchWaitSeconds 15)"
for i in $(seq 1 "$WAIT"); do
  orca terminal list --worktree "$WT" --json >/dev/null 2>&1 && break
  echo "Esperando a que Orca tenga listo el worktree ($i/$WAIT)..."; sleep 1
done

# Carpetas de trabajo de los agentes, ignoradas localmente
EVID="$(jq -r '.roles["visual-tester"].params.evidenceDir // "qa-evidence"' "$CFG")"
if COMMON="$(git rev-parse --git-common-dir 2>/dev/null)"; then
  mkdir -p "$COMMON/info"; touch "$COMMON/info/exclude"
  for p in research/ "$EVID/"; do grep -qxF "$p" "$COMMON/info/exclude" || echo "$p" >> "$COMMON/info/exclude"; done
fi

# shellcheck source=/dev/null
[ -f "$STATE" ] && . "$STATE"
ROLES="$(enabled_roles "$CFG" | tr '\n' ' ')"
NEW=""; RESUMED=""   # RESUMED: roles cuya pestaña anterior murió (p. ej. tras reiniciar); el Planner retoma el estado
for id in $ROLES; do
  v="$(var_of "$id")"; t="$(title_of "$CFG" "$id")"
  alive "${!v:-}" && continue
  [ -n "${!v:-}" ] && { RESUMED="$RESUMED $id"; echo "La pestaña anterior de $t (${!v}) ya no existe; se abre una nueva."; }
  h=""
  for try in 1 2 3; do
    h=$(orca terminal create --worktree "$WT" --title "$t" --command "ORCA_ROLES_CONFIG='$CFG' '$KIT/bin/agent.sh' $id" --json 2>&1 | handle_of)
    [ -n "$h" ] && break
    echo "Reintentando $t ($try/3)..."; sleep 2
  done
  [ -n "$h" ] || { echo "ERROR: no pude abrir $t. Revisa $LOG" >&2; exit 1; }
  printf -v "$v" '%s' "$h"; NEW="$NEW $id"
done

: > "$STATE"
for id in $ROLES; do v="$(var_of "$id")"; echo "$v=${!v}" >> "$STATE"; done
cat "$STATE"

if [ -z "$NEW" ]; then echo "Todos los roles ya están abiertos."; exit 0; fi
[ -n "$RESUMED" ] && echo "Retomando workspace: el Planner recuperará el estado anterior y te dará un resumen."
nohup "$KIT/bin/kickoff.sh" "$WT" "$STATE" "$CFG" "$NEW" "$RESUMED" > "$GITDIR/orca-roles-kickoff.log" 2>&1 &
echo "Arranque de roles en curso (log: $GITDIR/orca-roles-kickoff.log)"
