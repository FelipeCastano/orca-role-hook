#!/usr/bin/env bash
# Sends each agent its role, accepts the trust dialog if it appears, passes the Jira ticket to the front role (the local
# coordinator), tells it whether it is resuming a workspace (previous tabs dead) and closes the composer's extra agent session.
# Usage: kickoff.sh <worktree> <state> <config> "<new roles>" ["<resumed roles>" ["<remembered roles>" ["<reused roles>"]]]
#   resumed: reopened without memory (the front role recovers the state); remembered: reopened with their previous conversation;
#   reused: in <new roles> only because their tab never got its role message (same handle, not told to the front role as changed).
# Each role's handle is recorded in orca-roles.kicked (next to <state>) once its message is sent.
set -uo pipefail
WT="$1"; STATE="$2"; CFG="$3"; NEW="$4"; RESUMED="${5:-}"; REMEMBERED="${6:-}"; REUSED="${7:-}"
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
# shellcheck source=/dev/null
. "$STATE"
FRONT="$(front_role "$(mode_of --saved "$CFG" 2>/dev/null || echo programmer)" "$(dirname "$STATE")")"   # the role that owns the Run and talks to the user
FRONTV="$(var_of "$FRONT")"; FRONT_TO="${!FRONTV:-}"; FL="$(front_label "$FRONT")"; FLC="$(front_label "$FRONT" cap)"
ROLES="$(cut -d= -f1 "$STATE" | tr 'A-Z_' 'a-z-' | tr '\n' ' ')"
TIMEOUT_MS=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))
SETTLE="${ORCA_ROLES_KICK_SETTLE:-2}"
CHECK_PIDS=""; FRONT_MAIL=0
RESOLVED="$STATE"; RESOLVED_TMP=""   # the state file's lines with each role's live handle (see resolve_handles); the saved ones until it is written
trap 'rm -f "$(dirname "$STATE")/orca-roles.kickoff.d/$$"; [ -z "$RESOLVED_TMP" ] || rm -f "$RESOLVED_TMP"' EXIT

screen_of()   { orca terminal read --terminal "$1" --json 2>/dev/null | jq -r '.. | strings' 2>/dev/null; }
# OpenCode: text typed before its TUI has painted goes to the tab's shell, and orca terminal send still reports it accepted. For a tab this
# launch opened, wait until the screen shows the TUI (its footer's "ctrl+p" or its composer's "Ask anything"), once a second, at most
# kickoffTimeoutSeconds and never more than 30 s. 0 when the screen showed it, 1 when it gave up (kick() prints its own line for that).
# oc_wait_screen <handle>
oc_wait_screen() {
  local cap n=0; cap=$(( TIMEOUT_MS / 1000 )); [ "$cap" -le 30 ] || cap=30
  while ! { screen_of "$1" || true; } | grep -qE 'ctrl\+p|Ask anything'; do
    [ "$n" -lt "$cap" ] || return 1
    sleep "${ORCA_ROLES_SCREEN_POLL:-1}"; n=$((n + 1))
  done
  return 0
}
press_enter() { orca terminal send --terminal "$1" --enter --json >/dev/null 2>&1 || orca terminal send --terminal "$1" --text "" --enter --json >/dev/null 2>&1; }
front_err_code() {  # $1 output of a failed orca call: its .error.code, or nothing
  printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null | head -n 1 || true
}
front_err_text() {  # $1 output of a failed orca call, $2 its error code: one line saying why, at most 200 characters
  local msg
  if [ -n "$2" ]; then
    msg="$(printf '%s' "$1" | jq -r '.error.message // empty' 2>/dev/null | head -n 1 || true)"
    printf '%s\n' "${2}${msg:+: $msg}" | cut -c1-200
  else
    msg="$(printf '%s\n' "$1" | grep -m1 '[^[:space:]]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-200 || true)"
    printf '%s\n' "${msg:-no output}"
  fi
}
# front_send <subject> <body>: one status message to the front role, sent once more as its own tab when Orca finds no sender identity; 1 on failure with FRONT_ERR set.
front_send() {
  local out code
  FRONT_ERR=""
  out="$(orca orchestration send --to "$FRONT_TO" --type status --subject "$1" --body "$2" --json 2>&1)" && return 0
  code="$(front_err_code "$out")"
  if [ "$code" = no_active_sender_terminal ]; then
    out="$(orca orchestration send --from "$FRONT_TO" --to "$FRONT_TO" --type status --subject "$1" --body "$2" --json 2>&1)" && {
      echo "No Orca terminal identity here ($code): sent as $FL's own tab."; return 0; }
    code="$(front_err_code "$out")"
  fi
  FRONT_ERR="$(front_err_text "$out" "$code")"
  return 1
}
# handles_sent <what> <handle>: the kickoff log line naming the front role's handle in a message with the handles, after its send succeeded
handles_sent() { echo "Handles sent ($1): $FRONTV=$2"; }
state_handle() { printf '%s\n' "$1" | grep -m1 "^$FRONTV=" | cut -d= -f2-; }
# role_status <role>: one "Roles reopened" status to the front role about that role, right after its kick, with the roles still to kick and the handles
role_status() {
  local v t rest="" r after=0 first body
  v="$(var_of "$1")"; t="$(title_of "$CFG" "$1")"
  for r in $OPENED_IDS; do
    [ "$after" = 1 ] && rest="${rest:+$rest, }$(title_of "$CFG" "$r")"
    [ "$r" = "$1" ] && after=1
  done
  if [ "$(grep "^$v=" "$GITDIR/orca-roles.kicked" 2>/dev/null | head -1 | cut -d= -f2-)" = "${!v}" ]; then first="roles opened or reopened: $t."
  else first="roles opened or reopened: none. Not reached (no role message sent): $t."; fi
  [ -z "$rest" ] || first="$first Still starting: $rest."
  body="$first
Use these handles from now on:
$(cat "$RESOLVED")"
  if front_send "Roles reopened" "$body"; then echo "Told $FL the roles were reopened: $t."; handles_sent "Roles reopened" "$(state_handle "$(cat "$RESOLVED")")"; front_mail
  else echo "Could not tell $FL the roles were reopened: $t ($FRONT_ERR)."; fi
}
# all_runs: every Run (every page of run-list) as one JSON array; 1 if they cannot be listed
all_runs() {
  local cursor="" js runs="[]" i=0
  while [ "$i" -lt 50 ]; do
    if [ -n "$cursor" ]; then js="$(orca orchestration run-list --json --full --cursor "$cursor" 2>/dev/null)" || return 1
    else js="$(orca orchestration run-list --json --full 2>/dev/null)" || return 1; fi
    runs="$(printf '%s' "$js" | jq -c --argjson acc "$runs" '$acc + [(.result.runs // [])[]]' 2>/dev/null)" || return 1
    cursor="$(printf '%s' "$js" | jq -r '.result.nextCursor // empty' 2>/dev/null)" || return 1
    i=$((i + 1)); [ -n "$cursor" ] || break
  done
  printf '%s' "$runs"
}
# rebind_front_run <run id> <old handle>: binds the front role's stale Run to its live tab (FRONT_TO) once its agent is up and the new tab's
# SessionStart hook has had its 10 s (the hook's own run-use may have taken the Run already). REBIND is bound (nothing to tell the front role),
# other (another Run is bound to the live tab: binding this one would release it) or failed (the front role is told to run-use).
rebind_front_run() {
  local id="$1" old="$2" live="$FRONT_TO" n=0 before after cur out code wait="${ORCA_ROLES_REBIND_WAIT:-}" settle="${ORCA_ROLES_REBIND_SETTLE:-}" st
  case "$wait" in ''|*[!0-9]*) wait=30;; esac
  case "$settle" in ''|*[!0-9]*) settle=15;; esac
  REBIND=failed
  while [ -z "$(agent_pid_of_handle "$live")" ]; do
    if [ "$n" -ge "$wait" ]; then echo "Could not re-bind Run $id to $FL's tab: no agent runs in $live."; return 0; fi
    sleep 1; n=$((n + 1))
  done
  [ "$settle" -le 0 ] || sleep "$settle"
  before="$(all_runs)" || { echo "Could not re-bind Run $id to $FL's tab: run-list failed."; return 0; }
  cur="$(printf '%s' "$before" | jq -r --arg h "$live" '[.[] | select(.coordinator_handle == $h)] | max_by(.updated_at) | .id // empty' 2>/dev/null)"
  if [ -n "$cur" ]; then
    if [ "$cur" = "$id" ]; then REBIND=bound
    else REBIND=other; echo "Could not re-bind Run $id to $FL's tab: Run $cur is already bound to $live."; fi
    return 0
  fi
  st="$(printf '%s' "$before" | jq -r --argjson hs "$(jq -R . "$GITDIR/orca-roles.planner-handles" 2>/dev/null | jq -s . 2>/dev/null || echo '[]')" --arg cur "$live" \
    '[.[] | select(.coordinator_handle as $h | $h != $cur and ($hs | index($h)))] | max_by(.updated_at) // empty | "\(.id)\t\(.coordinator_handle)"' 2>/dev/null)" || st=""
  if [ -z "$st" ]; then REBIND=other; echo "Could not re-bind Run $id to $FL's tab: no stale Run is left."; return 0; fi
  IFS=$'\t' read -r id old <<<"$st"
  if out="$(orca orchestration run-use --id "$id" --from "$live" --json 2>&1)" && ! printf '%s' "$out" | jq -e '.ok == false' >/dev/null 2>&1; then :
  else
    code="$(front_err_code "$out")"
    echo "Could not re-bind Run $id to $FL's tab: run-use failed (${code:-no answer})."; return 0
  fi
  after="$(all_runs)" || after="[]"
  if [ "$(printf '%s' "$after" | jq -r --arg i "$id" '[.[] | select(.id == $i)][0].coordinator_handle // empty' 2>/dev/null)" != "$live" ]; then
    echo "Could not re-bind Run $id to $FL's tab: run-list does not show it on $live."
  else
    echo "Run $id was bound to an old ${FL#the } tab ($old); re-bound it to $FL's tab ($live)."; REBIND=bound
  fi
  jq -r -n --argjson b "$before" --argjson a "$after" --arg i "$id" '
    $b[] | select(.id != $i) | . as $x | ($a[] | select(.id == $x.id)) as $y
    | select(($x.coordinator_handle // "") != ($y.coordinator_handle // ""))
    | "Re-binding Run \($i) also moved Run \($x.id) from \(if ($x.coordinator_handle // "") == "" then "none" else $x.coordinator_handle end) to \(if ($y.coordinator_handle // "") == "" then "none" else $y.coordinator_handle end)."' 2>/dev/null || true
  return 0
}
# front_mail: once per kickoff, starts the kit's mail watcher (dispatch.sh --mail) on the front role's Run, so a status Orca leaves unannounced
# still gets a notice when no task is in flight. kickoff runs in the worktree (launch.sh starts it there), so dispatch.sh finds the git dir.
front_mail() {
  local run="" cursor="" js runs="[]" i=0
  [ "$FRONT_MAIL" = 1 ] && return 0
  FRONT_MAIL=1
  while [ "$i" -lt 50 ]; do   # every page of the Runs, as stale_run (lib.sh) reads them
    if [ -n "$cursor" ]; then js="$(orca orchestration run-list --json --full --cursor "$cursor" 2>/dev/null)" || break
    else js="$(orca orchestration run-list --json --full 2>/dev/null)" || break; fi
    runs="$(printf '%s' "$js" | jq -c --argjson acc "$runs" '$acc + [(.result.runs // [])[]]' 2>/dev/null)" || { runs="[]"; break; }
    cursor="$(printf '%s' "$js" | jq -r '.result.nextCursor // empty' 2>/dev/null)" || break
    i=$((i + 1)); [ -n "$cursor" ] || break
  done
  run="$(printf '%s' "$runs" | jq -r --arg h "$FRONT_TO" '[.[] | select(.coordinator_handle == $h)] | max_by(.updated_at) | .id // empty' 2>/dev/null)"
  if [ -z "$run" ]; then echo "No Run is bound to $FL's tab: no mail watcher for the status."; return 0; fi
  "$KIT/bin/dispatch.sh" --mail --run "$run" >/dev/null 2>&1 || true
  echo "Mail watcher started on Run $run for $FL."
}
# Orca can list the pre-restart handle of a tab next to its new one, and launch.sh writes the saved handle back for a role --open does not
# name, so orca-roles.env can name handles no tab carries any more. A handle counts as live when a claude, codex or OpenCode TUI process
# carries it as ORCA_TERMINAL_HANDLE (agent_pid_of_handle), the test launch.sh trusts for a tab that still works.
saved_pty() { grep "^$1=" "$(dirname "$STATE")/orca-roles.pty" 2>/dev/null | head -1 | cut -d= -f2-; }
# resolve_handles: one 'orca terminal list' for the whole kickoff, then <VAR>=<handle> for every state line, in its order: the saved handle
# when Orca lists it, then the handles with the role's saved ptyId, in list order; the first of them with a live agent, else the first
# (a custom agent, or a check that cannot see processes); the line is left out with no candidate. A failed list, or one with no handle,
# leaves a byte-for-byte copy of the state file.
resolve_handles() {
  local list n line v h p c cands first rf
  RESOLVED_TMP="$(mktemp "${TMPDIR:-/tmp}/orca-roles-handles.XXXXXX")" || { RESOLVED_TMP=""; return 0; }
  RESOLVED="$RESOLVED_TMP"
  list="$(orca terminal list --worktree "$WT" --json 2>/dev/null)" || list=""
  n="$(printf '%s' "$list" | jq -r '[.. | objects | select(has("handle"))] | length' 2>/dev/null)"; n="${n:-0}"
  case "$n" in ''|*[!0-9]*) n=0;; esac
  if [ "$n" -eq 0 ]; then cp "$STATE" "$RESOLVED"; return 0; fi
  while IFS= read -r line; do
    v="${line%%=*}"; h="${line#*=}"; p="$(saved_pty "$v")"; cands=""
    if printf '%s' "$list" | jq -e --arg h "$h" 'any(.. | objects | select(has("handle")); .handle == $h)' >/dev/null 2>&1; then cands="$h"; fi
    if [ -n "$p" ]; then
      while IFS= read -r c; do
        [ -z "$c" ] || cands="${cands:+$cands
}$c"
      done < <(printf '%s' "$list" | jq -r --arg p "$p" --arg h "$h" '[.. | objects | select(has("handle") and .ptyId == $p and .handle != $h) | .handle] | .[]' 2>/dev/null)
    fi
    first=""
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      [ -n "$first" ] || first="$c"
      if [ -n "$(agent_pid_of_handle "$c")" ]; then first="$c"; break; fi
    done <<< "$cands"
    [ -z "$first" ] || printf '%s=%s\n' "$v" "$first" >> "$RESOLVED"
  done < "$STATE"
  rf="$(grep "^$FRONTV=" "$RESOLVED" 2>/dev/null | head -1 | cut -d= -f2-)"
  [ -z "$rf" ] || FRONT_TO="$rf"   # a line left out keeps the saved handle: the messages go where they went before
  return 0
}
resolve_handles

MODELS="$(dirname "$STATE")/orca-roles.models"; MODELS_D="$MODELS.d"
# Model errors on the screen (wrapped lines joined, so one error counts once).  err_count <handle> <ERE>
err_count() { screen_of "$1" | tr -s ' \n\t' ' ' | grep -oE "$2" | wc -l | tr -d ' '; }
record_model() {  # $1 role, $2 value; merged into $MODELS once every check is done
  mkdir -p "$MODELS_D" && printf '%s=%s\n' "$(var_of "$1")" "$2" > "$MODELS_D/$(var_of "$1")"
}
merge_models() {
  local f v
  [ -d "$MODELS_D" ] || return 0
  for f in "$MODELS_D"/*; do
    [ -f "$f" ] || continue
    v="$(basename "$f")"
    { grep -v "^$v=" "$MODELS" 2>/dev/null || true; cat "$f"; } > "$MODELS.tmp" && mv "$MODELS.tmp" "$MODELS" && rm -f "$f"
  done
  rmdir "$MODELS_D" 2>/dev/null || true
}
tell_planner() {  # $1 subject, $2 body: to the front role
  [ -n "${!FRONTV:-}" ] || return 0
  front_send "$1" "$2" || echo "Could not tell $FL: $1 ($FRONT_ERR)"
}
# A role whose model does not exist answers its first message with an error (see model_error_regex): the kit only detects it and tells the front role.
model_failed() {  # $1 role, $2 model, $3 what showed it (the error text, or why the model is not available)
  local title; title="$(title_of "$CFG" "$1")"
  echo "$1: model $2 is not available ($3)"; record_model "$1" "FAILED:$2"
  [ "$1" = "$FRONT" ] || tell_planner "$title model unavailable" "$title did not start: its model $2 is not available ($3). config.json is unchanged. To fix it yourself: set roles.$1.model in ~/.orca-roles/config.json, then close its tab with ~/.orca-roles/bin/close-role.sh $1 and run roles --open $1 (without other options, so this worktree's saved options are kept)."
}
check_model() {  # $1 handle, $2 role, $3 model errors on screen before the message was sent, $4 error regex
  local model now text
  model="$(role_model "$CFG" "$2")"
  sleep "$SETTLE"; orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
  now="$(err_count "$1" "$4")"
  if [ "$now" -le "$3" ]; then record_model "$2" "$model"; return 0; fi
  text="$(screen_of "$1" | tr -s ' \n\t' ' ' | grep -oE "$4" | tail -n 1 | cut -c1-200 | sed 's/^ *//; s/ *$//')"
  model_failed "$2" "$model" "$text"
}
# OpenCode prints nothing for a model that does not exist, so for OpenCode the model is looked up in `opencode models`, run in
# the worktree (oc_bounded runs it at the top of the current one; $WT is an Orca selector, not a path). The first call after OpenCode's
# service starts can omit models while it warms up: one retry after a pause.
# Prints present, missing or unknown (the list could not be read twice).  oc_model_state <model, with or without #variant>
oc_model_state() {
  local m="${1%%#*}" out n rc=1
  out="$(mktemp)" || { echo unknown; return 0; }
  for n in 1 2; do
    oc_bounded "${ORCA_ROLES_OC_MODELS_TIMEOUT:-20}" "$out" models; rc="$OC_RC"
    if [ "$rc" = 0 ] && grep -qxF -- "$m" "$out"; then rm -f "$out"; echo present; return 0; fi
    [ "$n" = 1 ] && sleep "${ORCA_ROLES_OC_MODELS_RETRY:-3}"
  done
  rm -f "$out"
  if [ "$rc" = 0 ]; then echo missing; else echo unknown; fi
}

kicked_set() {  # kicked_set <role> <handle>: replaces that role's line (or adds it), atomically
  local f tmp v; f="$(dirname "$STATE")/orca-roles.kicked"; tmp="$f.tmp.$$"; v="$(var_of "$1")"; [ -f "$f" ] || : > "$f"
  k="$v" h="$2" awk 'index($0, ENVIRON["k"] "=") == 1 { if (!d) print ENVIRON["k"] "=" ENVIRON["h"]; d = 1; next } { print } END { if (!d) print ENVIRON["k"] "=" ENVIRON["h"] }' "$f" > "$tmp" && mv "$tmp" "$f"
}
TRUST="$(trust_of "$CFG")"
TRUST_RX='trust the files|trust this folder|do you trust|safety check|confías|confiar'   # confías/confiar: the Spanish-localized dialog
# With settings.trust "never" the user answers the dialog: wait (up to kickoffTimeoutSeconds) until it is gone. 1 if it never was.  wait_trust <handle> <title>
wait_trust() {
  local end; end=$(( $(date +%s) + (TIMEOUT_MS + 999) / 1000 + 1 ))   # whole seconds, so at least the full timeout
  echo "$2: waiting for you to answer the trust dialog in its tab"
  while { screen_of "$1" || true; } | grep -qiE "$TRUST_RX"; do
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep "${ORCA_ROLES_TRUST_POLL:-2}"
  done
}
# trust "never", Claude Code only. Text typed before the agent is past its trust dialog lands in that dialog and answers it (Claude
# Code exits), and Orca's screen text does not reliably show the dialog. Orca reports the agent (agentIdentity) only once the folder is
# trusted, so wait for that and type nothing before. 1 on timeout.  agent_trusted <handle> <title>
agent_of_tab() { orca terminal show --terminal "$1" --json 2>/dev/null | jq -r '[.. | objects | select(has("agentIdentity")) | .agentIdentity // empty] | first // empty' 2>/dev/null; }
agent_trusted() {
  local end; end=$(( $(date +%s) + (TIMEOUT_MS + 999) / 1000 + 1 ))
  [ -n "$(agent_of_tab "$1")" ] && return 0
  echo "$2: waiting for you to answer the trust dialog in its tab"
  while [ -z "$(agent_of_tab "$1")" ]; do
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep "${ORCA_ROLES_TRUST_POLL:-2}"
  done
}
kick() {  # $1 handle, $2 role, $3 message, [$4 "nokick": the message is not recorded as the role's kickoff]; 0 only when the message was sent
  local screen_trust=1 sent=1
  if [ "$TRUST" = never ]; then
    case "$(rstr "$CFG" "$2" agent)" in
      claude|"")
        agent_trusted "$1" "$(title_of "$CFG" "$2")" || {
          echo "$(title_of "$CFG" "$2"): its agent was not running in a trusted folder after ${TIMEOUT_MS} ms; its role was NOT sent. Answer the trust dialog, then run roles again: it sends the role to tabs that never got it."
          return 1; }
        screen_trust=0;;   # trusted: old dialog text still in the screen history must not be taken for an open dialog
    esac
  fi
  for _ in 1 2 3; do
    [ "$screen_trust" = 1 ] || { orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true; break; }
    orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
    if { screen_of "$1" || true; } | grep -qiE "$TRUST_RX"; then
      if [ "$TRUST" = never ]; then
        # Never press Enter or type the role here: it would accept the dialog. The role stays unmarked in orca-roles.kicked, so the next `roles` sends it.
        wait_trust "$1" "$(title_of "$CFG" "$2")" || {
          echo "$(title_of "$CFG" "$2"): the trust dialog was still open after ${TIMEOUT_MS} ms; its role was NOT sent. Answer the dialog, then run roles again: it sends the role to tabs that never got it."
          return 1; }
      else
        press_enter "$1"; echo "Trust dialog accepted in $1"; pace 3
      fi
    else break; fi
  done
  local before rx ocm="" model oc_ready=1 oc_started=0 oc_kind="" oc_sf="" oc_h="" oc_m="" cap=0 t=""; model="$(role_model "$CFG" "$2")"; rx="$(model_error_regex "$CFG" "$2" "$model")"
  if [ -n "$model" ] && [ "$(rstr "$CFG" "$2" agent)" = opencode ]; then
    ocm="$(oc_model_state "$model")"
    [ "$ocm" != unknown ] || echo "$2: could not check that model $model exists (opencode models failed)"
  fi
  if [ "$(rstr "$CFG" "$2" agent)" = opencode ]; then
    case " $REUSED " in
      *" $2 "*) ;;   # a reused tab: typed below, as before
      *)
        t="$(title_of "$CFG" "$2")"
        cap=$(( TIMEOUT_MS / 1000 )); [ "$cap" -le 30 ] || cap=30
        oc_wait_screen "$1" || oc_ready=0
        if [ "$2" != "$FRONT" ]; then
          # The marker agent.sh leaves when it passed the message with --prompt=: honoured whatever the screen check said, and deleted
          # either way, so a stale one never meets a later kick. A mismatch is the typed fallback, with one line naming why.
          oc_kind=new; remembers "$2" && oc_kind=back
          oc_sf="$(oc_started_file "$2")" || oc_sf=""
          [ -z "$oc_sf" ] || [ -f "$oc_sf" ] || oc_sf=""
          if [ -n "$oc_sf" ]; then
            { IFS= read -r oc_h; IFS= read -r oc_m; } < "$oc_sf" 2>/dev/null || true
            rm -f "$oc_sf"
            [ -n "$oc_h" ] || oc_sf=""   # an empty marker counts as no marker
          fi
          if [ -n "$oc_sf" ] && [ "$oc_h" = "$1" ] && [ "$oc_m" = "$oc_kind" ]; then
            oc_started=1
            if [ "$oc_ready" = 1 ]; then echo "Prompt passed at start to $1"
            else echo "$t: prompt passed at start to $1, but its OpenCode screen showed no prompt after $cap s; check that tab."; fi
          else
            [ "$oc_ready" = 1 ] || echo "$t: its OpenCode screen showed no prompt after $cap s; sending its role anyway."
            if [ -z "$oc_sf" ]; then echo "$t: its start left no prompt marker: typing its role."
            elif [ "$oc_h" != "$1" ]; then echo "$t: its start marker names another handle ($oc_h): typing its role."
            else echo "$t: its start marker is another kind ($oc_m, not $oc_kind): typing its role."; fi
          fi
        elif [ "$oc_ready" = 0 ]; then
          echo "$t: its OpenCode screen showed no prompt after $cap s; sending its role anyway."
        fi
        ;;
    esac
  fi
  if [ "$oc_started" = 1 ]; then
    # The message is already in OpenCode's argv: nothing is typed, and the error count starts from 0 (the screen was never sent it)
    before=0; sent=0
    [ "${4:-}" = nokick ] || kicked_set "$2" "$1"; [ "$2" != "$FRONT" ] || planner_history_add "$(dirname "$STATE")" "$1"
  else
    [ -z "$rx" ] || before="$(err_count "$1" "$rx")"
    if orca terminal send --terminal "$1" --text "$3" --enter --json >/dev/null; then
      echo "Prompt sent to $1"; [ "${4:-}" = nokick ] || kicked_set "$2" "$1"; [ "$2" != "$FRONT" ] || planner_history_add "$(dirname "$STATE")" "$1"; sent=0
    fi
  fi
  case "$ocm" in
    present) record_model "$2" "$model";;
    missing) model_failed "$2" "$model" "not in opencode models";;
  esac
  [ -z "$rx" ] || { check_model "$1" "$2" "$before" "$rx" & CHECK_PIDS="$CHECK_PIDS $!"; }
  return "$sent"
}
is_new() { case " $NEW " in *" $1 "*) return 0;; *) return 1;; esac; }
remembers() { case " $REMEMBERED " in *" $1 "*) return 0;; *) return 1;; esac; }

# The worktree's identity: branch and, if any, Jira key (Orca's linkedWorkItem or, without a link, the branch; see jira_key)
BRANCH="$(git branch --show-current 2>/dev/null)"
{ IFS= read -r JIRA_KEY; IFS= read -r JIRA_URL; } < <(worktree_jira "$WT" "$CFG")

# Closing the extra session Orca's composer opens when a worktree is created (the "done" tab). It runs in the background from the
# start, in parallel with the kickoff, because Claude Code renames that tab soon after. Only in a new worktree (launch.sh left
# the snapshot of the terminals that existed before the team), and only an agent terminal outside the team that either already
# existed before the team when Orca's setup script started the kit (see preexisting_agents), or whose FIRST title is the branch
# or starts with the Jira key, or whose screen showed the key (see seen_merge and composer_targets).
GITDIR="$(dirname "$STATE")"; PRE="$GITDIR/orca-roles.preexisting.json"; SEEN="$GITDIR/orca-roles.composer-seen.json"
ASK_START=0; [ -e "$GITDIR/orca-roles.mode-pending" ] && ASK_START=1
composer_watch() {
  local match ours tries targets h list
  [ "$(setting "$CFG" closeComposerAgent true)" = true ] || return 0
  [ -f "$PRE" ] || { echo "Not a new worktree: no extra session is looked for."; return 0; }
  local setupctx=0 pre_agents=""; [ -f "$GITDIR/orca-roles.setup-context" ] && setupctx=1
  match="$(composer_title_regex "$JIRA_KEY" "$BRANCH")"
  if [ -z "$match" ]; then
    [ "$setupctx" = 1 ] || { echo "No Jira key and no branch: no extra session is closed."; return 0; }
    match='a^'   # matches nothing: only the tabs that existed before the team count
  fi
  ours=$(cut -d= -f2 "$STATE" | jq -R . | jq -s -c .)
  [ "$setupctx" = 1 ] && pre_agents="$(preexisting_agents "$PRE" "$ours")"
  cp "$PRE" "$SEEN"
  tries=$(( $(setting "$CFG" composerAgentWindowSeconds 180) / 2 ))
  for _ in $(seq 1 "$tries"); do
    if list="$(orca terminal list --worktree "$WT" --json 2>/dev/null)"; then
      printf '%s' "$list" | seen_merge "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
    fi
    targets="$( { composer_targets "$SEEN" "$ours" "$match" "$JIRA_KEY"; printf '%s\n' "$pre_agents"; } | grep . | sort -u)"
    if [ -n "$targets" ]; then
      for h in $targets; do
        echo "Composer extra session detected ($h, first title: '$(jq -r --arg h "$h" '.[] | select(.handle == $h) | .title' "$SEEN")'); closing it."
        if orca terminal close --terminal "$h" --tab --json >/dev/null 2>&1; then echo "Closed $h"
        else  # older Orca without terminal close: ask the agent to exit
          orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1; pace 2
          orca terminal send --terminal "$h" --text "/exit" --enter --json >/dev/null && echo "/exit sent to $h"
        fi
      done
      return 0
    fi
    pace 2
  done
  echo "No composer extra session found (titles seen: $(jq -c '[.[] | select((.agentIdentity // "") != "") | .title]' "$SEEN"))."
}
composer_watch & WATCH_PID=$!

if is_new "$FRONT"; then
  RESUME=0; case " $RESUMED " in *" $FRONT "*) RESUME=1;; esac; remembers "$FRONT" && RESUME=2
  if { [ -n "${ORCA_ROLES_SWITCH_FROM:-}" ] || [ "${ORCA_ROLES_MODE_CHOSEN:-0}" = 1 ]; } && [ ! -e "$GITDIR/orca-roles.mode-pending" ]; then
    cmd=""; case " $REUSED $REMEMBERED " in *" $FRONT "*) cmd="$(clear_command "$CFG" "$FRONT")";; esac
    if [ -n "$cmd" ]; then
      orca terminal wait --terminal "${!FRONTV}" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
      orca terminal send --terminal "${!FRONTV}" --text $'\e' --json >/dev/null 2>&1
      pace 1
      orca terminal send --terminal "${!FRONTV}" --text "$cmd" --enter --json >/dev/null
      orca terminal wait --terminal "${!FRONTV}" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
      echo "$FLC's conversation was cleared ($cmd) for the mode $([ -n "${ORCA_ROLES_SWITCH_FROM:-}" ] && echo switch || echo choice)."
    else
      case " $REUSED $REMEMBERED " in
        *" $FRONT "*) echo "$FLC's agent has no clear command: its role message for the new mode goes into the same conversation.";;
        *) echo "$FLC has a new tab for this mode: nothing to clear.";;
      esac
    fi
    if [ -n "${ORCA_ROLES_SWITCH_FROM:-}" ]; then PLANNER_MSG="$(planner_msg "$CFG" "$ROLES" "$RESOLVED" "$JIRA_KEY" "$JIRA_URL" 4 "$ORCA_ROLES_SWITCH_FROM")"
    else PLANNER_MSG="$(planner_msg "$CFG" "$ROLES" "$RESOLVED" "$JIRA_KEY" "$JIRA_URL" "$RESUME")"; fi
  else
    PLANNER_MSG="$(planner_msg "$CFG" "$ROLES" "$RESOLVED" "$JIRA_KEY" "$JIRA_URL" "$RESUME")"
  fi
  planner_history_add "$GITDIR" ""   # seeds the handle history from the previous kicked/env files before kicked_set overwrites them
  if STALE="$(stale_run "$GITDIR" "$FRONT_TO")"; then
    if [ -n "$STALE" ]; then
      IFS=$'\t' read -r STALE_ID STALE_OLD STALE_OBJ <<<"$STALE"
      rebind_front_run "$STALE_ID" "$STALE_OLD"
      if [ "$REBIND" = failed ]; then
        PLANNER_MSG="$PLANNER_MSG Run $STALE_ID ($STALE_OBJ) is still bound to a previous tab of yours. If this is your Run, bind it with \`orca orchestration run-use --id $STALE_ID --json\` before anything else, so worker reports reach you."
        echo "Run $STALE_ID is bound to an old ${FL#the } tab ($STALE_OLD); $FL was told."
      fi
    fi
  else
    echo "Could not list the Runs to check $FL's binding."
  fi
  orca terminal wait --terminal "${!FRONTV}" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
  if [ -e "$GITDIR/orca-roles.mode-pending" ]; then kick "${!FRONTV}" "$FRONT" "$(planner_ask_msg "$CFG")" nokick
  elif [ "$ASK_START" = 1 ]; then echo "The mode was chosen while this kickoff waited: the choice's launch sends $FL its role message."
  else
    if kick "${!FRONTV}" "$FRONT" "$PLANNER_MSG"; then PSENT=1; handles_sent "role message" "${!FRONTV}"; else PSENT=0; fi
    # a coordinator's marker covers only this first start and is removed once the front role's role message is sent: its Run id stays beside the state (the front role keeps messaging that Run), the hold does not
    if [ "$RESUME" = 0 ] && CM="$(coordinated_marker)" && [ -f "$CM" ]; then
      if CR="$(coordinator_run "$STATE")"; then
        # the owner line: the handle that owned the Run when this first start copied the marker, so a later run-use that releases the Run
        # still leaves the worktree attributable to its coordinator (read once, here; its output and errors go nowhere)
        COWN=""
        if COUT="$(orca orchestration run-show --id "$CR" --json --full 2>/dev/null)"; then
          COWN="$(printf '%s' "$COUT" | jq -r 'if (.result.run.coordinator_handle | type) == "string" then .result.run.coordinator_handle else "" end' 2>/dev/null)"
          case "$COWN" in *[!A-Za-z0-9_-]*) COWN="";; esac
        fi
        { printf '%s\n' "$CR"; [ -z "$COWN" ] || printf '%s\n' "$COWN"; } > "$GITDIR/orca-roles.coordinator"
      fi
      if [ "$PSENT" = 1 ]; then rm -f "$CM"; else echo "Kept the coordinator's marker: $FL's role was not sent yet."; fi
    fi
  fi
  rm -f "$GITDIR/orca-roles.switch-from"
fi
OPENED_WORKERS=""; OPENED_IDS=""
for id in $ROLES; do   # the roles this launch opens or reopens, in kick order (a reused role is kicked but not listed)
  [ "$id" = "$FRONT" ] && continue
  is_new "$id" || continue
  case " $REUSED " in *" $id "*) ;; *) OPENED_WORKERS="${OPENED_WORKERS:+$OPENED_WORKERS, }$(title_of "$CFG" "$id")"; OPENED_IDS="$OPENED_IDS $id";; esac
done
PER_ROLE=0   # the front role ran this launch from its own tab: it is told about each role as soon as that role's kick ends
if ! is_new "$FRONT" && [ -n "${!FRONTV:-}" ] && [ "${ORCA_ROLES_SELF_RELAUNCH:-}" != 1 ] && [ "${ORCA_ROLES_SELF_NO_SESSION:-}" != 1 ] \
   && [ "${ORCA_ROLES_PLANNER_BUSY:-}" != 1 ] && [ "${ORCA_TERMINAL_HANDLE:-}" = "${!FRONTV}" ]; then PER_ROLE=1; fi
for id in $ROLES; do
  [ "$id" = "$FRONT" ] && continue
  is_new "$id" || continue
  v=$(var_of "$id")
  if remembers "$id"; then kick "${!v}" "$id" "$(worker_back_msg "$CFG" "$id" "${!v}")"; else kick "${!v}" "$id" "$(worker_msg "$CFG" "$id")"; fi
  case " $OPENED_IDS " in *" $id "*) [ "$PER_ROLE" = 1 ] && role_status "$id";; esac
done

# A live front role learns the new handles only from this message: its role message (with the handles) is sent only when it is (re)opened.
if ! is_new "$FRONT" && [ -n "$OPENED_WORKERS" ] && [ -n "${!FRONTV:-}" ]; then
  if [ "${ORCA_ROLES_SELF_RELAUNCH:-}" = 1 ]; then
    echo "$FLC will be reopened by its relauncher; its role message carries the handles."
  elif [ "${ORCA_ROLES_SELF_NO_SESSION:-}" = 1 ]; then
    echo "$FLC keeps its restored tab (its conversation could not be read, so it was not reopened); run roles from another terminal to give it the handles and the kit's settings."
  elif [ "${ORCA_ROLES_PLANNER_BUSY:-}" = 1 ]; then
    echo "$FLC's restored tab was busy and was not reopened; run roles again when it is idle: its role message will carry the handles."
  elif [ "${ORCA_TERMINAL_HANDLE:-}" = "${!FRONTV}" ]; then
    echo "$FLC was told about each role as its kick ended."
  else
    HANDLES_BODY="roles opened or reopened: $OPENED_WORKERS. Use these handles from now on:
$(cat "$RESOLVED")"
    if front_send "Role handles changed" "$HANDLES_BODY"; then
      echo "Told $FL the new handles."; handles_sent "Role handles changed" "$(state_handle "$(cat "$RESOLVED")")"
      front_mail
    else
      echo "Could not tell $FL the new handles ($FRONT_ERR); tell it to run: cat $STATE"
    fi
  fi
fi

for p in $CHECK_PIDS; do wait "$p"; done
merge_models
wait "$WATCH_PID"   # the composer watcher may still be polling
