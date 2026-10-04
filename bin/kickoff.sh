#!/usr/bin/env bash
# Sends each agent its role, accepts the trust dialog if it appears, passes the Jira ticket to the Planner,
# tells it whether it is resuming a workspace (previous tabs dead) and closes the composer's extra agent.
# Usage: kickoff.sh <worktree> <state> <config> "<new roles>" ["<resumed roles>"]
set -uo pipefail
WT="$1"; STATE="$2"; CFG="$3"; NEW="$4"; RESUMED="${5:-}"
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
# shellcheck source=/dev/null
. "$STATE"
ROLES="$(cut -d= -f1 "$STATE" | tr 'A-Z_' 'a-z-' | tr '\n' ' ')"
TIMEOUT_MS=$(( $(setting "$CFG" kickoffTimeoutSeconds 180) * 1000 ))

screen_of()   { orca terminal read --terminal "$1" --json 2>/dev/null | jq -r '.. | strings' 2>/dev/null; }
press_enter() { orca terminal send --terminal "$1" --enter --json >/dev/null 2>&1 || orca terminal send --terminal "$1" --text "" --enter --json >/dev/null 2>&1; }

kick() {  # $1 handle, $2 message
  for _ in 1 2 3; do
    orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$TIMEOUT_MS" --json >/dev/null || true
    if screen_of "$1" | grep -qiE 'trust the files|trust this folder|do you trust|confías|confiar'; then   # confías/confiar: the Spanish-localized dialog
      press_enter "$1"; echo "Trust dialog accepted in $1"; sleep 3
    else break; fi
  done
  orca terminal send --terminal "$1" --text "$2" --enter --json >/dev/null && echo "Prompt sent to $1"
}
is_new() { case " $NEW " in *" $1 "*) return 0;; *) return 1;; esac; }

# The worktree's identity: branch and, if any, Jira key (Orca's linkedWorkItem or, without a link, the branch; see jira_key)
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

# Closing the extra session Orca's composer opens. Only a terminal outside the team is touched,
# and only if its title is the branch name or starts with the Jira key (see composer_title_regex).
[ "$(setting "$CFG" closeComposerAgent true)" = true ] || exit 0
MATCH="$(composer_title_regex "$JIRA_KEY" "$BRANCH")"
if [ -z "$MATCH" ]; then echo "No Jira key and no branch: no extra session is closed."; exit 0; fi
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
      echo "Composer extra session detected ($h, title matches '$MATCH'); closing it."
      orca terminal send --terminal "$h" --text $'\e' --json >/dev/null 2>&1
      sleep 2
      orca terminal wait --terminal "$h" --for tui-idle --timeout-ms 30000 --json >/dev/null || true
      orca terminal send --terminal "$h" --text "/exit" --enter --json >/dev/null && echo "/exit sent to $h"
    done
    break
  fi
  sleep 5
done
