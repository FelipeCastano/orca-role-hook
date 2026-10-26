#!/usr/bin/env bash
# Sends each agent its role, accepts the trust dialog if it appears, passes the Jira ticket to the Planner,
# tells it whether it is resuming a workspace (previous tabs dead) and closes the composer's extra agent session.
# Usage: kickoff.sh <worktree> <state> <config> "<new roles>" ["<resumed roles>" ["<remembered roles>" ["<reused roles>"]]]
#   resumed: reopened without memory (the Planner recovers the state); remembered: reopened with their previous conversation;
#   reused: in <new roles> only because their tab never got its role message (same handle, not told to the Planner as changed).
# Each role's handle is recorded in orca-roles.kicked (next to <state>) once its message is sent.
set -uo pipefail
WT="$1"; STATE="$2"; CFG="$3"; NEW="$4"; RESUMED="${5:-}"; REMEMBERED="${6:-}"; REUSED="${7:-}"
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
# shellcheck source=/dev/null
. "$STATE"
ROLES="$(cut -d= -f1 "$STATE" | tr 'A-Z_' 'a-z-' | tr '\n' ' ')"
TIMEOUT_MS=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))
SETTLE="${ORCA_ROLES_KICK_SETTLE:-2}"
CHECK_PIDS=""
trap 'rm -f "$(dirname "$STATE")/orca-roles.kickoff.d/$$"' EXIT

screen_of()   { orca terminal read --terminal "$1" --json 2>/dev/null | jq -r '.. | strings' 2>/dev/null; }
press_enter() { orca terminal send --terminal "$1" --enter --json >/dev/null 2>&1 || orca terminal send --terminal "$1" --text "" --enter --json >/dev/null 2>&1; }

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
tell_planner() {  # $1 subject, $2 body
  [ -n "${PLANNER:-}" ] || return 0
  orca orchestration send --to "$PLANNER" --type escalation --subject "$1" --body "$2" --json >/dev/null 2>&1 || echo "Could not tell the Planner: $1"
}
# A role whose model does not exist answers its first message with an error (see model_error_regex): the kit only detects it and tells the Planner.
model_failed() {  # $1 role, $2 model, $3 what showed it (the error text, or why the model is not available)
  local title; title="$(title_of "$CFG" "$1")"
  echo "$1: model $2 is not available ($3)"; record_model "$1" "FAILED:$2"
  [ "$1" = planner ] || tell_planner "$title model unavailable" "$title did not start: its model $2 is not available ($3). config.json is unchanged. To fix it yourself: set roles.$1.model in ~/.orca-roles/config.json, then close its tab with ~/.orca-roles/bin/close-role.sh $1 and run roles (without options, so this worktree's saved options are kept)."
}
check_model() {  # $1 handle, $2 role, $3 model errors on screen before the message was sent, $4 error regex
  local model now text
  model="$(rstr "$CFG" "$2" model)"
  sleep "$SETTLE"; orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
  now="$(err_count "$1" "$4")"
  if [ "$now" -le "$3" ]; then record_model "$2" "$model"; return 0; fi
  text="$(screen_of "$1" | tr -s ' \n\t' ' ' | grep -oE "$4" | tail -n 1 | cut -c1-200 | sed 's/^ *//; s/ *$//')"
  model_failed "$2" "$model" "$text"
}
# `opencode mini` prints nothing for a model that does not exist, so for OpenCode the model is looked up in `opencode models`, run in
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
  local before rx ocm="" model; model="$(rstr "$CFG" "$2" model)"; rx="$(model_error_regex "$CFG" "$2" "$model")"
  if [ -n "$model" ] && [ "$(rstr "$CFG" "$2" agent)" = opencode ]; then
    ocm="$(oc_model_state "$model")"
    [ "$ocm" != unknown ] || echo "$2: could not check that model $model exists (opencode models failed)"
  fi
  [ -z "$rx" ] || before="$(err_count "$1" "$rx")"
  if orca terminal send --terminal "$1" --text "$3" --enter --json >/dev/null; then
    echo "Prompt sent to $1"; [ "${4:-}" = nokick ] || kicked_set "$2" "$1"; [ "$2" != planner ] || planner_history_add "$(dirname "$STATE")" "$1"; sent=0
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

if is_new planner; then
  RESUME=0; case " $RESUMED " in *" planner "*) RESUME=1;; esac; remembers planner && RESUME=2
  if [ -n "${ORCA_ROLES_SWITCH_FROM:-}" ] && [ ! -e "$GITDIR/orca-roles.mode-pending" ]; then
    cmd="$(clear_command "$CFG" planner)"
    if [ -n "$cmd" ]; then
      orca terminal wait --terminal "$PLANNER" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
      orca terminal send --terminal "$PLANNER" --text $'\e' --json >/dev/null 2>&1
      pace 1
      orca terminal send --terminal "$PLANNER" --text "$cmd" --enter --json >/dev/null
      orca terminal wait --terminal "$PLANNER" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
      echo "The Planner's conversation was cleared ($cmd) for the mode switch."
    else
      echo "The Planner's agent has no clear command: its role message for the new mode goes into the same conversation."
    fi
    PLANNER_MSG="$(planner_msg "$CFG" "$ROLES" "$STATE" "$JIRA_KEY" "$JIRA_URL" 4 "$ORCA_ROLES_SWITCH_FROM")"
  else
    PLANNER_MSG="$(planner_msg "$CFG" "$ROLES" "$STATE" "$JIRA_KEY" "$JIRA_URL" "$RESUME")"
  fi
  planner_history_add "$GITDIR" ""   # seeds the handle history from the previous kicked/env files before kicked_set overwrites them
  if STALE="$(stale_run "$GITDIR" "$PLANNER")"; then
    if [ -n "$STALE" ]; then
      IFS=$'\t' read -r STALE_ID STALE_OLD STALE_OBJ <<<"$STALE"
      PLANNER_MSG="$PLANNER_MSG Run $STALE_ID ($STALE_OBJ) is still bound to a previous tab of yours. If this is your Run, bind it with \`orca orchestration run-use --id $STALE_ID --json\` before anything else, so worker reports reach you."
      echo "Run $STALE_ID is bound to an old Planner tab ($STALE_OLD); the Planner was told."
    fi
  else
    echo "Could not list the Runs to check the Planner's binding."
  fi
  orca terminal wait --terminal "$PLANNER" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
  if [ -e "$GITDIR/orca-roles.mode-pending" ]; then kick "$PLANNER" planner "$(planner_ask_msg "$CFG")" nokick
  elif [ "$ASK_START" = 1 ]; then echo "The mode was chosen while this kickoff waited: the choice's launch sends the Planner its role message."
  else
    if kick "$PLANNER" planner "$PLANNER_MSG"; then PSENT=1; else PSENT=0; fi
    # a coordinator's marker covers only this first start and is removed once the Planner's role message is sent: its Run id stays beside the state (the Planner keeps messaging that Run), the hold does not
    if [ "$RESUME" = 0 ] && CM="$(coordinated_marker)" && [ -f "$CM" ]; then
      if CR="$(coordinator_run "$STATE")"; then printf '%s\n' "$CR" > "$GITDIR/orca-roles.coordinator"; fi
      if [ "$PSENT" = 1 ]; then rm -f "$CM"; else echo "Kept the coordinator's marker: the Planner's role was not sent yet."; fi
    fi
  fi
  rm -f "$GITDIR/orca-roles.switch-from"
fi
OPENED_WORKERS=""; OPENED_IDS=""
for id in $ROLES; do
  [ "$id" = planner ] && continue
  is_new "$id" || continue
  v=$(var_of "$id")
  case " $REUSED " in *" $id "*) ;; *) OPENED_WORKERS="${OPENED_WORKERS:+$OPENED_WORKERS, }$(title_of "$CFG" "$id")"; OPENED_IDS="$OPENED_IDS $id";; esac
  if remembers "$id"; then kick "${!v}" "$id" "$(worker_back_msg "$CFG" "$id" "${!v}")"; else kick "${!v}" "$id" "$(worker_msg "$CFG" "$id")"; fi
done

# A live Planner learns the new handles only from this message: its role message (with the handles) is sent only when it is (re)opened.
if ! is_new planner && [ -n "$OPENED_WORKERS" ] && [ -n "${PLANNER:-}" ]; then
  if [ "${ORCA_ROLES_SELF_RELAUNCH:-}" = 1 ]; then
    echo "The Planner will be reopened by its relauncher; its role message carries the handles."
  elif [ "${ORCA_ROLES_SELF_NO_SESSION:-}" = 1 ]; then
    echo "The Planner keeps its restored tab (its conversation could not be read, so it was not reopened); run roles from another terminal to give it the handles and the kit's settings."
  elif [ "${ORCA_ROLES_PLANNER_BUSY:-}" = 1 ]; then
    echo "The Planner's restored tab was busy and was not reopened; run roles again when it is idle: its role message will carry the handles."
  elif [ "${ORCA_TERMINAL_HANDLE:-}" = "$PLANNER" ]; then
    # the Planner ran this launch from its own tab: it learns the outcome from a status message, sent once every kick is done
    OK_TITLES=""; FAIL_TITLES=""
    for id in $OPENED_IDS; do
      v=$(var_of "$id")
      if [ "$(grep "^$v=" "$GITDIR/orca-roles.kicked" 2>/dev/null | head -1 | cut -d= -f2-)" = "${!v}" ]; then OK_TITLES="${OK_TITLES:+$OK_TITLES, }$(title_of "$CFG" "$id")"
      else FAIL_TITLES="${FAIL_TITLES:+$FAIL_TITLES, }$(title_of "$CFG" "$id")"; fi
    done
    REOPENED_BODY="roles opened or reopened: ${OK_TITLES:-none}.${FAIL_TITLES:+ Not reached (no role message sent): $FAIL_TITLES.}
Use these handles from now on:
$(cat "$STATE")"
    if orca orchestration send --to "$PLANNER" --type status --subject "Roles reopened" --body "$REOPENED_BODY" --json >/dev/null 2>&1; then
      echo "Told the Planner the roles were reopened."
    else
      echo "Could not tell the Planner the roles were reopened."
    fi
  else
    HANDLES_BODY="roles opened or reopened: $OPENED_WORKERS. Use these handles from now on:
$(cat "$STATE")"
    if orca orchestration send --to "$PLANNER" --type status --subject "Role handles changed" --body "$HANDLES_BODY" --json >/dev/null 2>&1; then
      echo "Told the Planner the new handles."
    else
      echo "Could not tell the Planner the new handles; tell it to run: cat $STATE"
    fi
  fi
fi

for p in $CHECK_PIDS; do wait "$p"; done
merge_models
wait "$WATCH_PID"   # the composer watcher may still be polling
