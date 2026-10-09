#!/usr/bin/env bash
# Wizard to create a new role: asks for its configuration and its prompt, and updates everything.
#
#   new-role                       # saves the role in your installation (~/.orca-roles)
#   new-role --repo <clone-path>   # saves it in your clone of the repo (versioned) and reinstalls
#   new-role --from-json <file> [--repo <clone-path>]   # without questions (used by the Planner's skill)
#   new-role --remove <id> [--repo <clone-path>]        # removes a role you created: its entry and its prompt
#     The JSON has: id, description and prompt (Markdown text) required; title, agent, model, permissionMode,
#     command, addDirFlag, trust, clearCommand, mcp, allowedTools, extraDirs, extraArgs, env, params, nice, pluginDirs,
#     enabled, after and overwrite optional.
set -euo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
TTY="${NEW_ROLE_TTY:-/dev/tty}"

REPO=""; FROM_JSON=""; REMOVE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2;;
    --from-json) FROM_JSON="${2:-}"; shift 2;;
    --remove) REMOVE="${2:-}"; shift 2;;
    -h|--help) sed -n 2,9p "$0"; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

# ---------- input helpers ----------
ask() {  # ask <variable> <question> [default]
  local __v="$1" __q="$2" __d="${3:-}" __a
  if [ -n "$__d" ]; then read -r -u 3 -p "$__q [$__d]: " __a; else read -r -u 3 -p "$__q: " __a; fi
  printf -v "$__v" '%s' "${__a:-$__d}"
}
ask_yn() {  # ask_yn <question> <y|n> → 0 if yes
  local a; read -r -u 3 -p "$1 [$( [ "$2" = y ] && echo Y/n || echo y/N )]: " a; a="${a:-$2}"
  case "$a" in y|Y|yes|Yes) return 0;; *) return 1;; esac
}
ask_lines() {  # ask_lines <variable> <question>: several lines, ends with an empty one
  local __v="$1" __l __acc=""
  echo "$2 (one per line; empty line to finish):"
  while IFS= read -r -u 3 -p "  > " __l && [ -n "$__l" ]; do __acc="$__acc$__l"$'\n'; done
  printf -v "$__v" '%s' "$__acc"
}
nonempty() { grep "${1:-.}" || true; }
lines_to_json() { printf '%s' "$1" | nonempty | jq -R . | jq -s . ; }
section() { echo; echo "── $1 ──"; }

# ---------- where it is saved ----------
if [ -n "$REPO" ]; then
  REPO="$(cd "$REPO" && pwd)"
  [ -f "$REPO/config.default.json" ] && [ -d "$REPO/prompts/programmer" ] || { echo "$REPO does not look like a clone of orca-roles." >&2; exit 1; }
  TARGET_CFG="$REPO/config.default.json"
  PROMPT_DIR="$REPO/prompts/programmer"
  echo "Repo mode: the role is saved in $REPO (remember to commit)."
else
  [ -f "$KIT/config.json" ] || cp "$KIT/config.default.json" "$KIT/config.json"
  TARGET_CFG="$KIT/config.json"
  PROMPT_DIR="$KIT/roles"          # not deleted when the kit is updated
  echo "Local mode: the role is saved in your installation ($TARGET_CFG)."
fi
mkdir -p "$PROMPT_DIR"

# Saves the role in the configuration (previous copy in .bak), after $AFTER.  Uses ID, AFTER, ROLE_JSON and NEW_SERVERS.
save_role() {
  cp "$TARGET_CFG" "$TARGET_CFG.bak"
  TMPC="$(mktemp)"
  jq --arg id "$ID" --arg after "$AFTER" --argjson role "$ROLE_JSON" --argjson servers "$NEW_SERVERS" '
    .mcpServers = ((.mcpServers // {}) + $servers)
    | .roles = (.roles | to_entries | map(select(.key != $id))
        | (map(.key) | index($after)) as $i
        | (.[0:$i+1] + [{key:$id, value:$role}] + .[$i+1:]) | from_entries)' "$TARGET_CFG" > "$TMPC"
  jq empty "$TMPC" && mv "$TMPC" "$TARGET_CFG"
  echo "Configuration updated: $TARGET_CFG (previous copy in $TARGET_CFG.bak)"
  if [ -n "$REPO" ]; then
    if [ -n "$FROM_JSON" ]; then echo "To apply it now, reinstall the kit: bash $REPO/install.sh"
    elif ask_yn "Reinstall the kit from the repo to apply it now?" y; then bash "$REPO/install.sh"; fi
    echo "Remember: cd $REPO && git add -A && git commit -m \"Add role: $ID\" && git push"
  fi
}

# ---------- remove a role: --remove ----------
if [ -n "$REMOVE" ]; then
  ID="$REMOVE"
  [ "$ID" != planner ] || { echo "'planner' cannot be removed" >&2; exit 1; }
  jq -e --arg r "$ID" '.roles | has($r)' "$TARGET_CFG" >/dev/null || { echo "Role '$ID' does not exist in $TARGET_CFG" >&2; exit 1; }
  if [ -z "$REPO" ] && jq -e --arg r "$ID" '.roles | has($r)' "$KIT/config.default.json" >/dev/null; then
    echo "'$ID' is a default role: removed from config.json, it would come back on the next update." >&2
    echo "Disable it instead: \"enabled\": false in $TARGET_CFG (or --disable $ID in a project's setup script)." >&2; exit 1
  fi
  P="$(jq -r --arg r "$ID" '.roles[$r].prompt // empty' "$TARGET_CFG")"; P="${P/#\~/$HOME}"; P="${P:-$PROMPT_DIR/$ID.md}"
  cp "$TARGET_CFG" "$TARGET_CFG.bak"
  TMPC="$(mktemp)"
  jq --arg r "$ID" 'del(.roles[$r])' "$TARGET_CFG" > "$TMPC" && jq empty "$TMPC" && mv "$TMPC" "$TARGET_CFG"
  echo "Removed role '$ID' from $TARGET_CFG (previous copy in $TARGET_CFG.bak)."
  # Only the prompt the kit manages is deleted (roles/<id>.md, or prompts/programmer/<id>.md in the repo), never a file elsewhere
  if [ "$P" = "$PROMPT_DIR/$ID.md" ] && [ -f "$P" ]; then rm -f "$P"; echo "Deleted its prompt: $P"
  elif [ -f "$P" ]; then echo "Its prompt is outside the kit and was left alone: $P"; fi
  [ -n "$REPO" ] && echo "Remember: reinstall (bash $REPO/install.sh) and commit."
  echo "If its tab is open in a workspace, close it from that worktree with: ~/.orca-roles/bin/close-role.sh $ID"
  exit 0
fi

# ---------- no-questions mode: --from-json ----------
if [ -n "$FROM_JSON" ]; then
  [ -f "$FROM_JSON" ] || { echo "$FROM_JSON does not exist" >&2; exit 1; }
  jq empty "$FROM_JSON" 2>/dev/null || { echo "$FROM_JSON is not valid JSON" >&2; exit 1; }
  J() { jq -r --arg k "$1" '.[$k] // empty | if type == "string" then . else tojson end' "$FROM_JSON"; }
  ID="$(J id)"; DESC="$(J description)"
  [[ "$ID" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "Invalid id (lowercase and hyphens): '$ID'" >&2; exit 1; }
  [ "$ID" != planner ] || { echo "'planner' is reserved" >&2; exit 1; }
  [ -n "$DESC" ] || { echo "Missing description (the Planner uses it to fit the role into the flow)" >&2; exit 1; }
  [ -n "$(J prompt)" ] || { echo "Missing prompt" >&2; exit 1; }
  AGENT="$(J agent)"; AGENT="${AGENT:-claude}"
  case "$AGENT" in claude|codex|custom) ;; *) echo "Invalid agent: $AGENT" >&2; exit 1;; esac
  [ "$AGENT" != custom ] || [ -n "$(J command)" ] || { echo "A custom agent needs a command" >&2; exit 1; }
  if jq -e --arg r "$ID" '.roles | has($r)' "$TARGET_CFG" >/dev/null && [ "$(J overwrite)" != true ]; then
    echo "Role '$ID' already exists; pass \"overwrite\": true to replace it" >&2; exit 1
  fi
  AFTER="$(J after)"; [ -n "$AFTER" ] || AFTER="$(jq -r --arg id "$ID" '.roles | keys_unsorted | map(select(. != $id)) | last' "$TARGET_CFG")"
  jq -e --arg r "$AFTER" '.roles | has($r)' "$TARGET_CFG" >/dev/null || { echo "Role '$AFTER' does not exist (after)" >&2; exit 1; }
  PROMPT_FILE="$PROMPT_DIR/$ID.md"
  J prompt > "$PROMPT_FILE"
  grep -q '^## Report' "$PROMPT_FILE" || echo "Warning: the prompt has no '## Report' section; check that it follows the pattern of the other roles."
  PROMPT_FIELD=""; [ -z "$REPO" ] && PROMPT_FIELD="$PROMPT_FILE"
  ROLE_JSON="$(jq --arg prompt "$PROMPT_FIELD" --arg agent "$AGENT" '
    {title: (.title // (.id | split("-") | map((.[:1] | ascii_upcase) + .[1:]) | join("-"))), description, enabled: (.enabled // true), agent: $agent}
    + (with_entries(select(.key | IN("model","permissionMode","command","addDirFlag","trust","clearCommand","mcp","allowedTools","extraDirs","extraArgs","env","params","nice","pluginDirs"))))
    + (if $prompt != "" then {prompt: $prompt} else {} end)' "$FROM_JSON")"
  NEW_SERVERS='{}'
  save_role
  echo "Prompt: $PROMPT_FILE"
  echo "Done. The role '$(jq -r .title <<<"$ROLE_JSON")' will appear in the worktrees you create from now on (or with 'roles' in an existing one)."
  exit 0
fi

exec 3< "$TTY"   # interactive input even if the script runs from a pipe

# ---------- identity ----------
section "Identity"
while :; do
  ask ID "Role id (lowercase and hyphens, e.g. security-reviewer)"
  [[ "$ID" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "  Invalid format."; continue; }
  [ "$ID" = planner ] && { echo "  'planner' is reserved."; continue; }
  if jq -e --arg r "$ID" '.roles | has($r)' "$TARGET_CFG" >/dev/null; then
    ask_yn "  '$ID' already exists. Overwrite it?" n && break || continue
  fi
  break
done
DEF_TITLE="$(echo "$ID" | awk -F- '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1' OFS=-)"
ask TITLE "Tab title" "$DEF_TITLE"
ask DESC "Description for the Planner: what it does and when to use it"
while [ -z "$DESC" ]; do ask DESC "  The description is required (the Planner uses it to fit the role into the flow)"; done

# ---------- agent and model ----------
section "Agent"
ask AGENT "Agent (claude | codex | custom)" "claude"
case "$AGENT" in claude|codex|custom) ;; *) echo "Invalid agent: $AGENT" >&2; exit 1;; esac
DEF_MODEL=""; [ "$AGENT" = claude ] && DEF_MODEL="claude-sonnet-5-5"
ask MODEL "Exact model (empty = the agent's default)" "$DEF_MODEL"
COMMAND=""; CLEAR=""; ADDDIR=""
if [ "$AGENT" = custom ]; then
  ask COMMAND "Command to run (accepts {model}, {prompts}, {prompt}, {mcp} and {scratch})"
  [ -n "$COMMAND" ] || { echo "A custom agent needs a command." >&2; exit 1; }
  ask CLEAR "Command that opens a new conversation in it, e.g. /new (empty = its context is never cleaned)"
  ask ADDDIR "Its flag to give it access to a folder, e.g. --add-dir (empty = none: no scratch folder or extra folders)"
fi
ask PERM "Permission mode (auto | acceptEdits | default)" "auto"

# ---------- MCP (any agent) and tools (claude only) ----------
MCP_JSON='[]'; TOOLS_JSON='null'; DIRS_JSON='[]'; NEW_SERVERS='{}'
section "MCP"
{
  AVAIL="$(jq -r '.mcpServers // {} | keys | join(", ")' "$TARGET_CFG")"
  echo "Defined servers: ${AVAIL:-none}"
  while ask_yn "Add a new MCP server to the configuration?" n; do
    ask SNAME "  Name"
    ask STYPE "  Type (http | stdio)" "http"
    if [ "$STYPE" = http ]; then
      ask SURL "  URL"
      NEW_SERVERS="$(jq --arg n "$SNAME" --arg u "$SURL" '. + {($n): {type:"http", url:$u}}' <<<"$NEW_SERVERS")"
    else
      ask SCMD "  Command (e.g. npx)"
      ask SARGS "  Space-separated arguments (e.g. -y @org/mcp@latest)"
      NEW_SERVERS="$(jq --arg n "$SNAME" --arg c "$SCMD" --arg a "$SARGS" '. + {($n): {command:$c, args:($a | split(" ") | map(select(. != "")))}}' <<<"$NEW_SERVERS")"
    fi
    AVAIL="${AVAIL:+$AVAIL, }$SNAME"
  done
  ask MCPSEL "The role's MCP: 'all' (the agent's own configuration), 'none', or comma-separated names" "none"
  case "$MCPSEL" in
    all) MCP_JSON='"all"';;
    none|"") MCP_JSON='[]';;
    *) MCP_JSON="$(echo "$MCPSEL" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | nonempty | jq -R . | jq -s .)";;
  esac
  [ "$AGENT" = custom ] && [ "$MCP_JSON" != '"all"' ] && echo "  Remember to use {mcp} (or \$ORCA_ROLES_MCP) in the command to pass the servers file to the agent."
}
if [ "$AGENT" = claude ]; then
  section "Tools"
  if ! ask_yn "Use the default allowed tools (orca orchestration and Read)?" y; then
    ask_lines TOOLS "Tools allowed without asking (e.g. Bash(npm test:*))"
    TOOLS_JSON="$(lines_to_json "$TOOLS")"
  fi
fi
if [ "$AGENT" != custom ] || [ -n "$ADDDIR" ]; then
  ask_lines DIRS "Extra folders it can access"
  DIRS_JSON="$(lines_to_json "$DIRS")"
fi

# ---------- other ----------
section "Other"
ask EXTRA "Extra CLI arguments, space-separated (optional)"
EXTRA_JSON="$(jq -n --arg a "$EXTRA" '$a | split(" ") | map(select(. != ""))')"
ask_lines ENVS "Environment variables as KEY=value"
ENV_JSON="$(printf '%s' "$ENVS" | nonempty '=' | jq -R 'split("=") | {(.[0]): (.[1:] | join("="))}' | jq -s 'add // {}')"
ask_lines PARAMS "Role parameters as key=value (e.g. maxFindings=20)"
PARAMS_JSON="$(printf '%s' "$PARAMS" | nonempty '=' | jq -R 'split("=") | {(.[0]): ((.[1:] | join("=")) as $v | try ($v | fromjson) catch $v)}' | jq -s 'add // {}')"

echo "Current order: $(jq -r '.roles | keys_unsorted | join(" → ")' "$TARGET_CFG")"
LAST="$(jq -r '.roles | keys_unsorted | map(select(. != "'"$ID"'")) | last' "$TARGET_CFG")"
ask AFTER "Place the tab after" "$LAST"
jq -e --arg r "$AFTER" '.roles | has($r)' "$TARGET_CFG" >/dev/null || { echo "Role '$AFTER' does not exist." >&2; exit 1; }
ENABLED=true; ask_yn "Enable it now?" y || ENABLED=false

# ---------- prompt ----------
# Every prompt follows the same pattern: mission, "When you receive a task", "Limits", "Parameters", "Report" and closing line.
section "Prompt"
PROMPT_FILE="$PROMPT_DIR/$ID.md"
echo "1) Generate it from a few questions"
echo "2) Use a file I already have"
echo "3) Write it in the editor (${EDITOR:-nano})"
ask PMODE "Option" "1"
write_skeleton() {  # write_skeleton <mission> <steps> <limits> <report> <verdict 0|1>
  local mission="$1" resp="$2" limits="$3" report="$4" verdict="$5"
  {
    echo "# Role: $(echo "$TITLE" | tr 'a-z' 'A-Z')"
    echo
    echo "$mission"
    echo
    echo "## When you receive a task"
    if [ -n "$resp" ]; then n=1; printf '%s' "$resp" | nonempty | while IFS= read -r l; do echo "$n. $l"; n=$((n+1)); done; else echo "1. "; fi
    echo
    echo "## Limits"
    if [ -n "$limits" ]; then printf '%s' "$limits" | nonempty | sed 's/^/- /'; else echo "- "; fi
    echo
    echo "## Parameters"
    if [ "$PARAMS_JSON" != "{}" ]; then
      echo "If they are not in your startup message, use these values:"
      jq -r 'to_entries[] | "- `\(.key)`: \(.value)"' <<<"$PARAMS_JSON"
    else
      echo "None."
    fi
    echo
    echo "## Report"
    echo "Report with \`worker_done\`:"
    if [ "$verdict" = 1 ]; then
      echo '- `--subject`: `VERDICT: ACCEPTED` or `VERDICT: REJECTED`'
      echo '- `--body`: first line same as the subject, and also:'
    else
      echo '- `--subject`: result in one line'
      echo '- `--body`:'
    fi
    if [ -n "$report" ]; then printf '%s' "$report" | nonempty | sed 's/^/  - /'; else echo "  - "; fi
    echo '- `--files-modified` with the paths you created or changed'
    if [ "$verdict" = 1 ]; then echo '- `--outcome succeeded` when the task was completed, even if you reject'
    else echo '- `--outcome succeeded` if you completed the task'; fi
    echo; echo "Now reply only \"$TITLE ready\" and wait for tasks."
  } > "$PROMPT_FILE"
}
case "$PMODE" in
  1)
    ask MISSION "The role's mission in one sentence" "$DESC"
    ask_lines RESP "What it does when it receives a task (steps)"
    ask_lines LIMITS "Limits: what it must NOT do"
    ask_lines REPORT "What its report must include"
    ask_yn "Does it issue an ACCEPTED/REJECTED verdict?" n && VERDICT=1 || VERDICT=0
    write_skeleton "$MISSION" "$RESP" "$LIMITS" "$REPORT" "$VERDICT"
    ask_yn "Open it in the editor to review it?" n && "${EDITOR:-nano}" "$PROMPT_FILE" < "$TTY" > "$TTY"
    ;;
  2)
    ask SRCF "File path"; SRCF="${SRCF/#\~/$HOME}"
    [ -f "$SRCF" ] || { echo "$SRCF does not exist" >&2; exit 1; }
    cp "$SRCF" "$PROMPT_FILE"
    grep -q '^## Report' "$PROMPT_FILE" || echo "Warning: the prompt has no '## Report' section; check that it follows the pattern of the other roles (see README → Creating a new role)."
    ;;
  3)
    write_skeleton "$DESC" "" "" "" 0
    "${EDITOR:-nano}" "$PROMPT_FILE" < "$TTY" > "$TTY"
    ;;
  *) echo "Invalid option" >&2; exit 1;;
esac

# ---------- build the role and save ----------
PROMPT_FIELD=""; [ -z "$REPO" ] && PROMPT_FIELD="$PROMPT_FILE"   # in the repo the default path (prompts/programmer/<id>.md) works
ROLE_JSON="$(jq -n \
  --arg title "$TITLE" --arg desc "$DESC" --argjson enabled "$ENABLED" \
  --arg agent "$AGENT" --arg model "$MODEL" --arg perm "$PERM" --arg command "$COMMAND" --arg clear "$CLEAR" --arg adddir "$ADDDIR" \
  --argjson mcp "$MCP_JSON" --argjson tools "$TOOLS_JSON" --argjson dirs "$DIRS_JSON" \
  --argjson extra "$EXTRA_JSON" --argjson env "$ENV_JSON" --argjson params "$PARAMS_JSON" \
  --arg prompt "$PROMPT_FIELD" '
  {title:$title, description:$desc, enabled:$enabled, agent:$agent}
  + (if $model != "" then {model:$model} else {} end)
  + (if $perm != "auto" then {permissionMode:$perm} else {} end)
  + (if $command != "" then {command:$command} else {} end)
  + (if $clear != "" then {clearCommand:$clear} else {} end)
  + (if $adddir != "" then {addDirFlag:$adddir} else {} end)
  + {mcp:$mcp}
  + (if $tools != null then {allowedTools:$tools} else {} end)
  + (if ($dirs | length) > 0 then {extraDirs:$dirs} else {} end)
  + (if ($extra | length) > 0 then {extraArgs:$extra} else {} end)
  + (if ($env | length) > 0 then {env:$env} else {} end)
  + (if ($params | length) > 0 then {params:$params} else {} end)
  + (if $prompt != "" then {prompt:$prompt} else {} end)')"

section "Summary"
echo "Role '$ID' (after '$AFTER'):"
jq . <<<"$ROLE_JSON"
[ "$NEW_SERVERS" != "{}" ] && { echo "New MCP servers:"; jq . <<<"$NEW_SERVERS"; }
echo "Prompt: $PROMPT_FILE"
ask_yn "Save?" y || { echo "Cancelled (the prompt was left in $PROMPT_FILE)."; exit 1; }

save_role
echo "Done. The role '$TITLE' will appear in the worktrees you create from now on (or with 'roles' in an existing one)."
