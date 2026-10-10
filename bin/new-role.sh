#!/usr/bin/env bash
# Wizard to create a new role: asks for its configuration and its prompt, and updates everything.
#
#   new-role                       # saves the role in your installation (~/.orca-roles)
#   new-role --repo <clone-path>   # saves it in your clone of the repo (versioned) and reinstalls
#   new-role --from-json <file> [--repo <clone-path>]   # without questions (used by the Planner's skill)
#   new-role --remove <id> [--repo <clone-path>]        # removes a role you created: its entry and its prompts
#     The JSON has: id, description and prompt required; modes, title, agent, model, permissionMode, command,
#     addDirFlag, trust, clearCommand, mcp, allowedTools, extraDirs, extraArgs, env, params, nice, pluginDirs, enabled,
#     after and overwrite optional.
#     modes: "all", or one mode id (a string or a one-element list); missing = "programmer". prompt: Markdown text
#     (a role with one mode) or {"<mode>": "<Markdown>"} covering exactly the role's modes ("all" = every mode).
#     Each mode has its own prompt file: roles/<mode>/<id>.md (local) or prompts/<mode>/<id>.md (--repo).
set -euo pipefail
KIT="$HOME/.orca-roles"; . "$KIT/bin/lib.sh"
TTY="${NEW_ROLE_TTY:-/dev/tty}"

REPO=""; FROM_JSON=""; REMOVE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2;;
    --from-json) FROM_JSON="${2:-}"; shift 2;;
    --remove) REMOVE="${2:-}"; shift 2;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p;}' "$0"; exit 0;;
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
  PROMPT_ROOT="$REPO/prompts"      # <mode>/<id>.md
  echo "Repo mode: the role is saved in $REPO (remember to commit)."
else
  [ -f "$KIT/config.json" ] || cp "$KIT/config.default.json" "$KIT/config.json"
  TARGET_CFG="$KIT/config.json"
  PROMPT_ROOT="$KIT/roles"         # <mode>/<id>.md, not deleted when the kit is updated
  echo "Local mode: the role is saved in your installation ($TARGET_CFG)."
fi

# Whether $1 is one of the words of the list $2
in_list() { case " $2 " in *" $1 "*) return 0;; esac; return 1; }
# Ids that are kit files, not roles: prompts/<mode>/common-workers.md and the planner's prompt
reserved_id() { [ "$1" = planner ] || [ "$1" = common-workers ]; }
# A mode counts as unavailable when it has no planner prompt: in the clone with --repo, in the installation otherwise
mode_unavailable() { if [ -n "$REPO" ]; then [ ! -f "$REPO/prompts/$1/planner.md" ]; else [ -n "$(mode_error "$1")" ]; fi; }
# In the clone a new role must not take over a prompt file that is already there (a kit file): refuses with the first one found
repo_collision_check() {  # uses ID and NEW_MODES
  local m
  [ -n "$REPO" ] || return 0
  jq -e --arg r "$ID" '.roles | has($r)' "$TARGET_CFG" >/dev/null && return 0
  for m in $NEW_MODES; do
    if [ -e "$REPO/prompts/$m/$ID.md" ] || [ -L "$REPO/prompts/$m/$ID.md" ]; then
      echo "$REPO/prompts/$m/$ID.md already exists and '$ID' is not a role of config.default.json: choose another id" >&2; return 1
    fi
  done
}
# Overwriting a role leaves no orphans. Local: deletes the kit-managed prompts (exact paths) of the modes it no longer has, and the legacy roles/<id>.md.
# In the repo: only lists them (they are versioned files, the user removes them with git).
drop_orphan_prompts() {
  local m f
  for m in $MODE_IDS; do
    in_list "$m" "$NEW_MODES" && continue
    f="$PROMPT_ROOT/$m/$ID.md"
    [ -f "$f" ] || [ -L "$f" ] || continue
    if [ -n "$REPO" ]; then echo "prompts/$m/$ID.md is no longer used by '$ID'; remove it with: git -C $REPO rm prompts/$m/$ID.md"
    else rm -f "$f"; echo "Deleted the prompt of a mode the role no longer has: $f"; fi
  done
  f="$KIT/roles/$ID.md"
  if [ -z "$REPO" ] && { [ -f "$f" ] || [ -L "$f" ]; }; then rm -f "$f"; echo "Deleted its old prompt: $f"; fi
}

# Saves the role in the configuration (previous copy in .bak), after $AFTER.  Uses ID, AFTER, ROLE_JSON, NEW_SERVERS and NEW_MODES.
save_role() {
  local existed=0
  jq -e --arg r "$ID" '.roles | has($r)' "$TARGET_CFG" >/dev/null && existed=1
  cp "$TARGET_CFG" "$TARGET_CFG.bak"
  TMPC="$(mktemp)"
  jq --arg id "$ID" --arg after "$AFTER" --argjson role "$ROLE_JSON" --argjson servers "$NEW_SERVERS" '
    .mcpServers = ((.mcpServers // {}) + $servers)
    | .roles = (.roles | to_entries | map(select(.key != $id))
        | (map(.key) | index($after)) as $i
        | (.[0:$i+1] + [{key:$id, value:$role}] + .[$i+1:]) | from_entries)' "$TARGET_CFG" > "$TMPC"
  jq empty "$TMPC" && mv "$TMPC" "$TARGET_CFG"
  echo "Configuration updated: $TARGET_CFG (previous copy in $TARGET_CFG.bak)"
  [ "$existed" = 0 ] || drop_orphan_prompts
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
  [ "$ID" != common-workers ] || { echo "'common-workers' is a kit file, not a role" >&2; exit 1; }
  jq -e --arg r "$ID" '.roles | has($r)' "$TARGET_CFG" >/dev/null || { echo "Role '$ID' does not exist in $TARGET_CFG" >&2; exit 1; }
  if [ -z "$REPO" ] && jq -e --arg r "$ID" '.roles | has($r)' "$KIT/config.default.json" >/dev/null; then
    echo "'$ID' is a default role: removed from config.json, it would come back on the next update." >&2
    echo "Disable it instead: \"enabled\": false in $TARGET_CFG (or --disable $ID in a project's setup script)." >&2; exit 1
  fi
  [[ "$ID" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "Invalid id: '$ID'" >&2; exit 1; }
  # Only the prompts the kit manages are deleted, at their exact paths (<mode>/<id>.md under roles/ or prompts/, and the legacy roles/<id>.md), never a file elsewhere
  MANAGED=""; for m in $MODE_IDS; do MANAGED="$MANAGED$PROMPT_ROOT/$m/$ID.md"$'\n'; done
  [ -n "$REPO" ] || MANAGED="$MANAGED$KIT/roles/$ID.md"$'\n'
  CFG_PROMPTS="$(jq -r --arg r "$ID" '.roles[$r].prompt | if type == "string" then . elif type == "object" then (.[] | strings) else empty end' "$TARGET_CFG")"
  cp "$TARGET_CFG" "$TARGET_CFG.bak"
  TMPC="$(mktemp)"
  jq --arg r "$ID" 'del(.roles[$r])' "$TARGET_CFG" > "$TMPC" && jq empty "$TMPC" && mv "$TMPC" "$TARGET_CFG"
  echo "Removed role '$ID' from $TARGET_CFG (previous copy in $TARGET_CFG.bak)."
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f" ] || [ -L "$f" ]; then rm -f "$f"; echo "Deleted its prompt: $f"; fi
  done <<<"$MANAGED"
  while IFS= read -r f; do
    f="${f/#\~/$HOME}"
    if [ -f "$f" ] && ! printf '%s' "$MANAGED" | grep -Fxq -- "$f"; then echo "Its prompt is outside the kit and was left alone: $f"; fi
  done <<<"$CFG_PROMPTS"
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
  ! reserved_id "$ID" || { echo "'$ID' is reserved" >&2; exit 1; }
  [ -n "$DESC" ] || { echo "Missing description (the Planner uses it to fit the role into the flow)" >&2; exit 1; }
  # modes: "all", one mode id (string or one-element list); missing = programmer. Mode ids are matched exactly (mode_error), never used as a path before that.
  MODES_FIELD="$(jq -c 'if has("modes") then .modes else "programmer" end
    | if . == "all" then . elif type == "string" then [.]
      elif type == "array" and length == 1 and (.[0] | type) == "string" then .
      else error("x") end' "$FROM_JSON" 2>/dev/null)" \
    || { echo "Invalid modes: use \"all\" or one mode id (modes: $MODE_LIST)" >&2; exit 1; }
  if [ "$MODES_FIELD" = '"all"' ]; then NEW_MODES="$MODE_IDS"
  else
    NEW_MODES="$(jq -j '.[0]' <<<"$MODES_FIELD"; printf x)"; NEW_MODES="${NEW_MODES%x}"   # the sentinel keeps a trailing newline in the id
    case "$(mode_error "$NEW_MODES")" in unknown*) echo "Invalid modes: $(mode_error "$NEW_MODES")" >&2; exit 1;; esac
  fi
  NEW_MODES_JSON="$(tr ' ' '\n' <<<"$NEW_MODES" | jq -R . | jq -sc .)"
  PROMPT_ERR="$(jq -r --argjson modes "$NEW_MODES_JSON" '.prompt as $p
    | if $p == null then "Missing prompt"
      elif ($p | type) == "string" then
        (if ($modes | length) != 1 then "A string prompt is only for a role with one mode; use an object {\"<mode>\": prompt} with every mode of the role (\($modes | join(", ")))"
         elif ($p | test("\\S") | not) then "Missing prompt" else empty end)
      elif ($p | type) == "object" then
        (($p | keys) as $k | ($k - $modes) as $extra | ($modes - $k) as $miss
         | if ($extra | length) > 0 then "The prompt has modes the role does not have: \($extra | join(", "))"
           elif ($miss | length) > 0 then "The prompt is missing the mode(s): \($miss | join(", "))"
           elif ([$p[] | select((type != "string") or (test("\\S") | not))] | length) > 0 then "The prompt of every mode must be non-empty Markdown text"
           else empty end)
      else "The prompt must be Markdown text or an object {\"<mode>\": Markdown}" end' "$FROM_JSON")"
  [ -z "$PROMPT_ERR" ] || { echo "$PROMPT_ERR" >&2; exit 1; }
  repo_collision_check || exit 1
  AGENT="$(J agent)"; AGENT="${AGENT:-claude}"
  case "$AGENT" in claude|codex|custom) ;; *) echo "Invalid agent: $AGENT" >&2; exit 1;; esac
  [ "$AGENT" != custom ] || [ -n "$(J command)" ] || { echo "A custom agent needs a command" >&2; exit 1; }
  if jq -e --arg r "$ID" '.roles | has($r)' "$TARGET_CFG" >/dev/null && [ "$(J overwrite)" != true ]; then
    echo "Role '$ID' already exists; pass \"overwrite\": true to replace it" >&2; exit 1
  fi
  AFTER="$(J after)"; [ -n "$AFTER" ] || AFTER="$(jq -r --arg id "$ID" '.roles | keys_unsorted | map(select(. != $id)) | last' "$TARGET_CFG")"
  jq -e --arg r "$AFTER" '.roles | has($r)' "$TARGET_CFG" >/dev/null || { echo "Role '$AFTER' does not exist (after)" >&2; exit 1; }
  PROMPT_OBJ='{}'; PROMPT_FILES=""
  for m in $NEW_MODES; do
    f="$PROMPT_ROOT/$m/$ID.md"; mkdir -p "$PROMPT_ROOT/$m"
    jq -r --arg m "$m" '.prompt | if type == "string" then . else .[$m] end' "$FROM_JSON" > "$f"
    grep -q '^## Report' "$f" || echo "Warning: the prompt for mode $m has no '## Report' section; check that it follows the pattern of the other roles."
    PROMPT_OBJ="$(jq -c --arg m "$m" --arg f "$f" '. + {($m): $f}' <<<"$PROMPT_OBJ")"
    PROMPT_FILES="$PROMPT_FILES  $m: $f"$'\n'
    ! mode_unavailable "$m" || echo "Note: mode '$m' is not available yet; the role will launch once that mode exists."
  done
  [ -z "$REPO" ] || PROMPT_OBJ='{}'   # in the repo the default path (prompts/<mode>/<id>.md) works
  ROLE_JSON="$(jq --argjson prompt "$PROMPT_OBJ" --argjson modes "$MODES_FIELD" --arg agent "$AGENT" '
    {title: (.title // (.id | split("-") | map((.[:1] | ascii_upcase) + .[1:]) | join("-"))), description, enabled: (.enabled // true), agent: $agent}
    + (with_entries(select(.key | IN("model","permissionMode","command","addDirFlag","trust","clearCommand","mcp","allowedTools","extraDirs","extraArgs","env","params","nice","pluginDirs"))))
    + {modes: $modes}
    + (if ($prompt | length) > 0 then {prompt: $prompt} else {} end)' "$FROM_JSON")"
  NEW_SERVERS='{}'
  save_role
  printf 'Prompts:\n%s' "$PROMPT_FILES"
  echo "Done. The role '$(jq -r .title <<<"$ROLE_JSON")' will appear in the worktrees you create from now on (or with 'roles' in an existing one)."
  exit 0
fi

exec 3< "$TTY"   # interactive input even if the script runs from a pipe

# ---------- identity ----------
section "Identity"
while :; do
  ask ID "Role id (lowercase and hyphens, e.g. security-reviewer)"
  [[ "$ID" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "  Invalid format."; continue; }
  reserved_id "$ID" && { echo "  '$ID' is reserved."; continue; }
  if jq -e --arg r "$ID" '.roles | has($r)' "$TARGET_CFG" >/dev/null; then
    ask_yn "  '$ID' already exists. Overwrite it?" n && break || continue
  fi
  break
done
DEF_TITLE="$(echo "$ID" | awk -F- '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1' OFS=-)"
ask TITLE "Tab title" "$DEF_TITLE"
ask DESC "Description for the Planner: what it does and when to use it"
while [ -z "$DESC" ]; do ask DESC "  The description is required (the Planner uses it to fit the role into the flow)"; done

# ---------- modes ----------
section "Modes"
echo "1) All modes"
echo "2) Only one"
ask MSEL "In all modes or in one?" "2"
case "$MSEL" in
  1) MODES_FIELD='"all"'; NEW_MODES="$MODE_IDS";;
  2)
    i=0; for m in $MODE_IDS; do i=$((i+1)); if mode_unavailable "$m"; then echo "  $i) $m (not available yet)"; else echo "  $i) $m"; fi; done
    ask MPICK "Mode (number)" "1"
    NEW_MODES=""; i=0; for m in $MODE_IDS; do i=$((i+1)); if [ "$MPICK" = "$i" ] || [ "$MPICK" = "$m" ]; then NEW_MODES="$m"; fi; done
    [ -n "$NEW_MODES" ] || { echo "Invalid mode" >&2; exit 1; }
    MODES_FIELD="[\"$NEW_MODES\"]";;
  *) echo "Invalid option" >&2; exit 1;;
esac
repo_collision_check || exit 1
for m in $NEW_MODES; do
  ! mode_unavailable "$m" || echo "  Note: mode '$m' is not available yet; the role will launch once that mode exists."
done

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
    echo "Report with \`worker_done\`, following the Output rules (the body stays complete):"
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
ask_prompt() {  # ask_prompt <mode> <previous mode, if any>: writes $PROMPT_FILE
  echo "Prompt for mode $1:"
  echo "1) Generate it from a few questions"
  echo "2) Use a file I already have"
  echo "3) Write it in the editor (${EDITOR:-nano})"
  [ -z "$2" ] || echo "4) Copy the prompt of $2"
  ask PMODE "Option" "1"
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
    4)
      [ -n "$2" ] || { echo "Invalid option" >&2; exit 1; }
      cp "$PREV_FILE" "$PROMPT_FILE"
      ;;
    *) echo "Invalid option" >&2; exit 1;;
  esac
}
PROMPT_OBJ='{}'; PROMPT_FILES=""; PREV_MODE=""; PREV_FILE=""
for m in $NEW_MODES; do
  PROMPT_FILE="$PROMPT_ROOT/$m/$ID.md"; mkdir -p "$PROMPT_ROOT/$m"
  ask_prompt "$m" "$PREV_MODE"
  PROMPT_OBJ="$(jq -c --arg m "$m" --arg f "$PROMPT_FILE" '. + {($m): $f}' <<<"$PROMPT_OBJ")"
  PROMPT_FILES="$PROMPT_FILES  $m: $PROMPT_FILE"$'\n'
  PREV_MODE="$m"; PREV_FILE="$PROMPT_FILE"
done

# ---------- build the role and save ----------
[ -z "$REPO" ] || PROMPT_OBJ='{}'   # in the repo the default path (prompts/<mode>/<id>.md) works
ROLE_JSON="$(jq -n \
  --arg title "$TITLE" --arg desc "$DESC" --argjson enabled "$ENABLED" \
  --arg agent "$AGENT" --arg model "$MODEL" --arg perm "$PERM" --arg command "$COMMAND" --arg clear "$CLEAR" --arg adddir "$ADDDIR" \
  --argjson mcp "$MCP_JSON" --argjson tools "$TOOLS_JSON" --argjson dirs "$DIRS_JSON" \
  --argjson extra "$EXTRA_JSON" --argjson env "$ENV_JSON" --argjson params "$PARAMS_JSON" \
  --argjson prompt "$PROMPT_OBJ" --argjson modes "$MODES_FIELD" '
  {title:$title, description:$desc, enabled:$enabled, agent:$agent, modes:$modes}
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
  + (if ($prompt | length) > 0 then {prompt:$prompt} else {} end)')"

section "Summary"
echo "Role '$ID' (after '$AFTER'):"
jq . <<<"$ROLE_JSON"
[ "$NEW_SERVERS" != "{}" ] && { echo "New MCP servers:"; jq . <<<"$NEW_SERVERS"; }
printf 'Prompts:\n%s' "$PROMPT_FILES"
ask_yn "Save?" y || { echo "Cancelled (the prompts were left in the files above)."; exit 1; }

save_role
echo "Done. The role '$TITLE' will appear in the worktrees you create from now on (or with 'roles' in an existing one)."
