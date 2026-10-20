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
check_model() {  # $1 handle, $2 role, $3 model errors on screen before the message was sent, $4 error regex
  local model title now text
  model="$(rstr "$CFG" "$2" model)"; title="$(title_of "$CFG" "$2")"
  sleep "$SETTLE"; orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
  now="$(err_count "$1" "$4")"
  if [ "$now" -le "$3" ]; then record_model "$2" "$model"; return 0; fi
  text="$(screen_of "$1" | tr -s ' \n\t' ' ' | grep -oE "$4" | tail -n 1 | cut -c1-200 | sed 's/^ *//; s/ *$//')"
  echo "$2: model $model is not available ($text)"; record_model "$2" "FAILED:$model"
  [ "$2" = planner ] || tell_planner "$title model unavailable" "$title did not start: its model $model is not available ($text). config.json is unchanged. To fix it yourself: set roles.$2.model in ~/.orca-roles/config.json, then close its tab with ~/.orca-roles/bin/close-role.sh $2 and run roles (without options, so this worktree's saved options are kept)."
}

kicked_set() {  # kicked_set <role> <handle>: replaces that role's line (or adds it), atomically
  local f tmp v; f="$(dirname "$STATE")/orca-roles.kicked"; tmp="$f.tmp.$$"; v="$(var_of "$1")"; [ -f "$f" ] || : > "$f"
  awk -v k="$v" -v h="$2" 'index($0, k "=") == 1 { if (!d) print k "=" h; d = 1; next } { print } END { if (!d) print k "=" h }' "$f" > "$tmp" && mv "$tmp" "$f"
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
kick() {  # $1 handle, $2 role, $3 message
  for _ in 1 2 3; do
    orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
    if { screen_of "$1" || true; } | grep -qiE "$TRUST_RX"; then
      if [ "$TRUST" = never ]; then
        # Never press Enter or type the role here: it would accept the dialog. The role stays unmarked in orca-roles.kicked, so the next `roles` sends it.
        wait_trust "$1" "$(title_of "$CFG" "$2")" || {
          echo "$(title_of "$CFG" "$2"): the trust dialog was still open after ${TIMEOUT_MS} ms; its role was NOT sent. Answer the dialog, then run roles again: it sends the role to tabs that never got it."
          return 0; }
      else
        press_enter "$1"; echo "Trust dialog accepted in $1"; sleep 3
      fi
    else break; fi
  done
  local before rx; rx="$(model_error_regex "$CFG" "$2" "$(rstr "$CFG" "$2" model)")"
  [ -z "$rx" ] || before="$(err_count "$1" "$rx")"
  orca terminal send --terminal "$1" --text "$3" --enter --json >/dev/null && { echo "Prompt sent to $1"; kicked_set "$2" "$1"; }
  [ -z "$rx" ] || { check_model "$1" "$2" "$before" "$rx" & CHECK_PIDS="$CHECK_PIDS $!"; }
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
          orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1; sleep 2
          orca terminal send --terminal "$h" --text "/exit" --enter --json >/dev/null && echo "/exit sent to $h"
        fi
      done
      return 0
    fi
    sleep 2
  done
  echo "No composer extra session found (titles seen: $(jq -c '[.[] | select((.agentIdentity // "") != "") | .title]' "$SEEN"))."
}
composer_watch & WATCH_PID=$!

if is_new planner; then
  RESUME=0; case " $RESUMED " in *" planner "*) RESUME=1;; esac; remembers planner && RESUME=2
  kick "$PLANNER" planner "$(planner_msg "$CFG" "$ROLES" "$STATE" "$JIRA_KEY" "$JIRA_URL" "$RESUME")"
fi
OPENED_WORKERS=""
for id in $ROLES; do
  [ "$id" = planner ] && continue
  is_new "$id" || continue
  v=$(var_of "$id")
  case " $REUSED " in *" $id "*) ;; *) OPENED_WORKERS="${OPENED_WORKERS:+$OPENED_WORKERS, }$(title_of "$CFG" "$id")";; esac
  if remembers "$id"; then kick "${!v}" "$id" "$(worker_back_msg "$CFG" "$id" "${!v}")"; else kick "${!v}" "$id" "$(worker_msg "$CFG" "$id")"; fi
done

# A live Planner learns the new handles only from this message: its role message (with the handles) is sent only when it is (re)opened.
if ! is_new planner && [ -n "$OPENED_WORKERS" ] && [ -n "${PLANNER:-}" ]; then
  if [ "${ORCA_TERMINAL_HANDLE:-}" = "$PLANNER" ]; then
    echo "Not telling the Planner the new handles: it ran this launch itself."
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
