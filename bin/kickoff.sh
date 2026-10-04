#!/usr/bin/env bash
# Sends each agent its role, accepts the trust dialog if it appears, passes the Jira ticket to the Planner,
# tells it whether it is resuming a workspace (previous tabs dead) and closes the composer's extra agent session.
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
  RESUME=0; case " $RESUMED " in *" planner "*) RESUME=1;; esac
  kick "$PLANNER" "$(planner_msg "$CFG" "$ROLES" "$STATE" "$JIRA_KEY" "$JIRA_URL" "$RESUME")"
fi
for id in $ROLES; do
  [ "$id" = planner ] && continue
  is_new "$id" || continue
  v=$(var_of "$id")
  kick "${!v}" "$(worker_msg "$CFG" "$id")"
done

wait "$WATCH_PID"   # the composer watcher may still be polling
