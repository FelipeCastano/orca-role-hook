#!/usr/bin/env bash
# Envía su rol a cada agente, acepta el diálogo de confianza si aparece, pasa el ticket de Jira al Planner,
# le indica si está retomando un workspace (pestañas anteriores muertas) y cierra el agente extra del composer.
# Uso: kickoff.sh <worktree> <state> <config> "<roles nuevos>" ["<roles retomados>"]
set -uo pipefail
WT="$1"; STATE="$2"; CFG="$3"; NEW="$4"; RESUMED="${5:-}"
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
# shellcheck source=/dev/null
. "$STATE"
ROLES="$(cut -d= -f1 "$STATE" | tr 'A-Z_' 'a-z-' | tr '\n' ' ')"
TIMEOUT_MS=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))

screen_of()   { orca terminal read --terminal "$1" --json 2>/dev/null | jq -r '.. | strings' 2>/dev/null; }
press_enter() { orca terminal send --terminal "$1" --enter --json >/dev/null 2>&1 || orca terminal send --terminal "$1" --text "" --enter --json >/dev/null 2>&1; }

kick() {  # $1 handle, $2 mensaje
  for _ in 1 2 3; do
    orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
    if screen_of "$1" | grep -qiE 'trust the files|trust this folder|do you trust|confías|confiar'; then
      press_enter "$1"; echo "Diálogo de confianza aceptado en $1"; sleep 3
    else break; fi
  done
  orca terminal send --terminal "$1" --text "$2" --enter --json >/dev/null && echo "Prompt enviado a $1"
}
is_new() { case " $NEW " in *" $1 "*) return 0;; *) return 1;; esac; }

# Identidad del worktree: rama y, si la hay, clave de Jira (linkedWorkItem de Orca o, si no hay enlace, la rama; ver jira_key)
BRANCH="$(git branch --show-current 2>/dev/null)"
WT_JSON="$(orca worktree show --worktree "$WT" --json 2>/dev/null)"
JIRA_ID=$(printf '%s' "$WT_JSON" | jq -r '[.. | objects | select(.provider? == "jira") | .jiraIdentifier // empty] | first // empty' 2>/dev/null)
JIRA_URL=$(printf '%s' "$WT_JSON" | jq -r '[.. | objects | select(.provider? == "jira") | .url // empty] | first // ([.. | strings | select(test("atlassian\\.net/browse/"))] | first) // empty' 2>/dev/null)
JIRA_KEY="$(jira_key "$BRANCH" "$JIRA_ID" "$JIRA_URL")"
[ "$(setting "$CFG" jiraHandoff true)" = true ] || JIRA_KEY=""

if is_new planner; then
  RESUME=0; case " $RESUMED " in *" planner "*) RESUME=1;; esac
  kick "$PLANNER" "$(planner_msg "$CFG" "$ROLES" "$STATE" "$JIRA_KEY" "$JIRA_URL" "$RESUME")"
fi
for id in $ROLES; do
  [ "$id" = planner ] && continue
  is_new "$id" || continue
  v=$(var_of "$id")
  kick "${!v}" "$(worker_msg "$CFG" "$id")"
done

# Cierre de la sesión extra que abre el composer de Orca. Solo se toca una terminal ajena al equipo
# cuyo título es el nombre de la rama o empieza por la clave de Jira (ver composer_title_regex).
[ "$(setting "$CFG" closeComposerAgent true)" = true ] || exit 0
MATCH="$(composer_title_regex "$JIRA_KEY" "$BRANCH")"
if [ -z "$MATCH" ]; then echo "Sin clave de Jira ni rama: no se cierra ninguna sesión extra."; exit 0; fi
OURS=$(cut -d= -f2 "$STATE" | jq -R . | jq -s .)
TRIES=$(( $(setting "$CFG" composerAgentWindowSeconds 180) / 5 ))
for _ in $(seq 1 "$TRIES"); do
  extra=$(orca terminal list --worktree "$WT" --json | jq -r --argjson ours "$OURS" --arg re "$MATCH" '
    [.. | objects | select(has("handle"))
      | select(.handle as $h | $ours | index($h) | not)
      | select((.title // "") | test($re; "i"))
      | .handle] | unique | .[]')
  if [ -n "$extra" ]; then
    for h in $extra; do
      echo "Sesión extra del composer detectada ($h, título coincide con '$MATCH'); cerrándola."
      orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1
      sleep 2
      orca terminal wait --terminal "$h" --for tui-idle --timeout-ms 30000 --json >/dev/null || true
      orca terminal send --terminal "$h" --text "/exit" --enter --json >/dev/null && echo "/exit enviado a $h"
    done
    break
  fi
  sleep 5
done
