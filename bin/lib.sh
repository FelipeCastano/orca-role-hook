# shellcheck shell=bash
# Shared functions. Requires jq. Compatible with bash 3.2 (macOS) and with GNU/BSD tools.
KIT="${KIT:-$HOME/.orca-roles}"

# Orca's CLI is not always called 'orca': in the WSL terminals Orca manages on Windows it is $ORCA_CLI_COMMAND
# (e.g. orca-ide). If 'orca' is not on the PATH but Orca names another command, the $KIT/shim/orca wrapper is created and
# prepended to the PATH: the kit's scripts, the prompts and the agents (which inherit the PATH) keep using 'orca'.
orca_shim() {
  local real="${ORCA_CLI_COMMAND:-}" dir="$KIT/shim" tmp
  command -v orca >/dev/null 2>&1 && return 0
  { [ -n "$real" ] && [ "$real" != orca ] && command -v "$real" >/dev/null 2>&1; } || return 0
  mkdir -p "$dir" && tmp="$(mktemp "$dir/.orca.XXXXXX")" || return 0
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real" > "$tmp" && chmod +x "$tmp" && mv "$tmp" "$dir/orca"
  PATH="$dir:$PATH"; export PATH
}
orca_shim

# Effective config: ~/.orca-roles/config.json (or the default one) + the project's .orca-roles.json, if any.
# .orca-roles.json is looked up at the worktree root and, if missing (e.g. not committed), at the main checkout root.
merged_config() {  # $1 = project/worktree folder
  local base="$KIT/config.json" proj
  [ -f "$base" ] || base="$KIT/config.default.json"
  proj="$(project_config "${1:-.}")"
  if [ -n "$proj" ]; then jq -s --argjson l "$LEGACY_ROLES" "$LEGACY_JQ"' (.[0] | legacy($l)) * (.[1] | legacy($l))' "$base" "$proj"; else jq --argjson l "$LEGACY_ROLES" "$LEGACY_JQ"' legacy($l)' "$base"; fi
}
# Path of the .orca-roles.json that applies to a folder (empty if none).  project_config <folder>
project_config() {
  local top common main
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -f "$top/.orca-roles.json" ] && { echo "$top/.orca-roles.json"; return 0; }
  common="$(cd "$1" && git rev-parse --git-common-dir 2>/dev/null)" || return 0
  main="$(cd "$1" && cd "$common/.." && pwd)"
  [ -f "$main/.orca-roles.json" ] && echo "$main/.orca-roles.json"
  return 0
}
# A role's value, inheriting from defaults:  rcfg <config> <role> <field>
rcfg() { jq -c --arg r "$2" --arg k "$3" '(.roles[$r][$k]) // (.defaults[$k]) // empty' "$1"; }
rstr() { jq -r --arg r "$2" --arg k "$3" '(.roles[$r][$k]) // (.defaults[$k]) // empty' "$1"; }
setting() { jq -r --arg k "$2" --arg d "$3" '(.settings[$k]) // $d | tostring' "$1"; }
# Enabled roles in order; the planner always runs
enabled_roles() { jq -r '.roles | to_entries[] | select(.key == "planner" or .value.enabled != false) | .key' "$1"; }
title_of() { jq -r --arg r "$2" '.roles[$r].title // $r' "$1"; }
var_of()   { echo "$1" | tr 'a-z-' 'A-Z_'; }
# A role's prompt file: the "prompt" field (accepts ~), or the kit's prompts/<role>.md
prompt_of() { local p; p="$(jq -r --arg r "$2" '.roles[$r].prompt // empty' "$1")"; p="${p/#\~/$HOME}"; echo "${p:-$KIT/prompts/$2.md}"; }
# Updates a user configuration with the new keys/roles of the default one, without overwriting values or the order of their roles.
# Roles renamed between versions (old id → new id), applied to the user's config, .orca-roles.json and the setup script options.
LEGACY_ROLES='{"visual-tester": "e2e-tester"}'
LEGACY_JQ='def legacy($l): if (.roles? | type) == "object" then .roles |= (to_entries | map(if $l[.key] then .key = $l[.key] | (if .value.title == "Visual-Tester" then .value.title = "E2E-Tester" else . end) else . end) | from_entries) else . end;'
upgrade_config() {  # $1 = config.default.json, $2 = the user's config.json → stdout
  jq -s --argjson l "$LEGACY_ROLES" "$LEGACY_JQ"' .[0] as $d | (.[1] | legacy($l)) as $u | ($d * $u) as $m
    | $m | .roles = ((($u.roles | keys_unsorted) + (($d.roles | keys_unsorted) - ($u.roles | keys_unsorted)))
                     | map({key: ., value: $m.roles[.]}) | from_entries)' "$1" "$2"
}
# launch.sh exceptions (options of the project's setup script, or of 'roles') as JSON:
#   {"only": [...], "enable": [...], "disable": [...], "set": [{"path": [...], "value": ...}]}
# overrides_from_args [--only a,b] [--enable a,b] [--disable a,b] [--set dotted.path=value] ...  → stdout; 1 on error
# Lists add up if an option repeats. In --set the value is read as JSON if it is JSON (true, 10, ["x"]) and as text otherwise.
overrides_from_args() {
  local o='{"only":[],"enable":[],"disable":[],"set":[]}' opt val k
  while [ $# -gt 0 ]; do
    case "$1" in
      --only=*|--enable=*|--disable=*|--set=*) opt="${1%%=*}"; val="${1#*=}";;
      --only|--enable|--disable|--set) opt="$1"; [ $# -ge 2 ] || { echo "ERROR: $1 needs a value" >&2; return 1; }; val="$2"; shift;;
      *) echo "ERROR: unknown option: $1" >&2; return 1;;
    esac
    shift
    k="${opt#--}"
    if [ "$k" = set ]; then
      case "$val" in *=*) ;; *) echo "ERROR: --set expects path=value (e.g. roles.dev.model=claude-opus-5-5): $val" >&2; return 1;; esac
      o="$(jq -c --arg p "${val%%=*}" --arg v "${val#*=}" --argjson l "$LEGACY_ROLES" '.set += [{path: ($p | split(".") | if .[0] == "roles" and $l[.[1]] then .[1] = $l[.[1]] else . end), value: ($v | try fromjson catch $v)}]' <<<"$o")"
    else
      o="$(jq -c --arg k "$k" --arg v "$val" --argjson l "$LEGACY_ROLES" '.[$k] += ($v | split(",") | map(gsub("^ +| +$"; "")) | map(select(. != "")) | map($l[.] // .))' <<<"$o")"
    fi
  done
  printf '%s\n' "$o"
}
# Checks that the exceptions only name existing roles and do not disable the planner.  check_overrides <config> <overrides>
check_overrides() {
  jq -r --slurpfile o "$2" '(.roles | keys) as $ks | $o[0] as $o
    | ([$o.only[], $o.enable[], $o.disable[]] | unique | map(select(. as $r | $ks | index($r) | not))
       | if length > 0 then "ERROR: unknown roles: \(join(", ")). Available: \($ks | join(", "))" else empty end),
      (if ($o.disable | index("planner")) then "ERROR: the planner cannot be disabled" else empty end)' "$1"
}
# Applies the exceptions to a configuration: --only (the planner always stays), then --enable, --disable and --set.  apply_overrides <config> <overrides>
apply_overrides() {
  jq --slurpfile o "$2" '$o[0] as $o
    | if ($o.only | length) > 0 then .roles |= with_entries(.value.enabled = (.key == "planner" or (.key as $k | $o.only | index($k)) != null)) else . end
    | reduce $o.enable[] as $r (.; .roles[$r].enabled = true)
    | reduce $o.disable[] as $r (.; .roles[$r].enabled = false)
    | reduce $o.set[] as $s (.; setpath($s.path; $s.value))' "$1"
}
# Escapes a text to use it literally inside a regular expression
regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|\\]/\\&/g'; }
# The worktree's Jira key.  jira_key <branch> <Orca's jiraIdentifier> <ticket url>
# Orca stores a linked worktree's ticket in linkedWorkItem (provider "jira", jiraIdentifier, url): that wins.
# Without a link (worktree created by hand, 'roles' in a checkout), it is taken from the branch only if the key, in uppercase,
# starts the branch or one of its segments (DEVGD-220-x, feature/DEVGD-220), so fix-123 or release-1.4 are not taken for tickets.
jira_key() {
  local k=""
  if [ -n "$2" ]; then k="$2"
  elif [ -n "$3" ]; then k="$(printf '%s' "$3" | grep -oE 'browse/[A-Za-z][A-Za-z0-9_]+-[0-9]+' | head -1)"; k="${k#browse/}"
  else k="$(printf '%s' "$1" | grep -oE '(^|/)[A-Z][A-Z0-9_]+-[0-9]+' | head -1)"; k="${k#/}"
  fi
  printf '%s' "$k" | tr 'a-z' 'A-Z'
}
# Expression (jq, case-insensitive) the title of the composer's extra session must match for it to be closed:
# it starts with the Jira key followed by a separator or the end ("DEVGD-220", "DEVGD-220: summary"),
# or it is exactly the branch name. Empty if there is neither key nor branch.  composer_title_regex <key> <branch>
composer_title_regex() {
  local alts=""
  [ -n "$1" ] && alts="$(regex_escape "$1")([^A-Za-z0-9_-].*)?"
  [ -n "$2" ] && alts="${alts:+$alts|}$(regex_escape "$2")"
  [ -n "$alts" ] && printf '^(%s)$' "$alts"
  return 0
}
# First sighting of each terminal: adds to the list in <seen file> (a JSON array, or empty/missing) the terminals of an
# `orca terminal list --json` (stdin) not seen before, with the title and preview they had then.  seen_merge <seen file> < list
# Why: Claude Code renames its tab with a summary of the task ("done"...), so the composer's extra session is recognized by the
# title it had when it was first seen, not by the current one.
seen_merge() {
  local seen='[]'; [ -s "${1:-}" ] && seen="$(cat "$1")"
  jq -c --argjson seen "$seen" '[.. | objects | select(has("handle")) | {handle, title, preview, agentIdentity}] as $cur
    | $seen + [$cur[] | select(.handle as $h | ($seen | map(.handle) | index($h)) | not)] | unique_by(.handle)'
}
# Handles of the composer's extra session among the first sightings: an agent (agentIdentity set), outside the team, whose first
# title matches composer_title_regex or whose screen showed the Jira key.  composer_targets <seen file> <ours json array> <regex> <key>
composer_targets() {
  jq -r --argjson ours "$2" --arg re "$3" --arg key "$4" '.[]
    | select(.handle as $h | $ours | index($h) | not)
    | select((.agentIdentity // "") != "")
    | select(((.title // "") | test($re; "i"))
             or ($key != "" and ((.preview // "") | test("(^|[^A-Za-z0-9])" + $key + "([^0-9]|$)"; "i"))))
    | .handle' "$1"
}
# Agent tabs that already existed before the team in a new worktree, outside the team: when the kit was started by Orca's
# setup script, those can only be the composer's extra session, whatever its title ("✳ Claude Code", "done"...).
# preexisting_agents <snapshot file> <ours json array>
preexisting_agents() {
  [ -s "$1" ] || return 0
  jq -r --argjson ours "$2" '.[] | select(.handle as $h | $ours | index($h) | not) | select((.agentIdentity // "") != "") | .handle' "$1"
}
# The Planner's startup message.  planner_msg <config> "<enabled roles>" <state> <jira_key> <jira_url> <resume 0|1>
planner_msg() {
  local cfg="$1" roles="$2" state="$3" key="$4" url="$5" resume="$6" id v t handles="" active="" extra params msg lang
  # shellcheck source=/dev/null
  . "$state"
  for id in $roles; do
    [ "$id" = planner ] && continue
    v="$(var_of "$id")"; t="$(title_of "$cfg" "$id")"
    handles="$handles $t=${!v},"; active="$active $t"
  done
  extra="$(jq -r --argjson act "$(printf '%s\n' $roles | grep . | jq -R . | jq -s .)" \
    '[.roles | to_entries[] | select(.key != "planner" and (.key as $k | $act | index($k)) and .value.description) | "\(.value.title // .key): \(.value.description)"] | join("; ")' "$cfg")"
  params="$(jq -r '((.defaults.params // {}) * (.roles.planner.params // {})) | to_entries | map("\(.key)=\(.value)") | join(", ")' "$cfg")"
  msg="Read $(prompt_of "$cfg" planner) and adopt that role from now on. Active roles in this workspace:${active:- none}. Handles:${handles%,}."
  lang="$(setting "$cfg" language auto)"   # settings.language: "auto" = the language the user writes in
  [ "$lang" != auto ] && [ -n "$lang" ] && msg="$msg Always reply to the user in $lang, whatever language they write in."
  [ -n "$params" ] && msg="$msg Configuration parameters: $params."
  [ -n "$extra" ] && msg="$msg Additional roles (fit them into the flow according to their description): $extra."
  if [ "$(setting "$cfg" cleanWorkersAfterStep true)" = true ]; then msg="$msg When closing each step, propose to the user cleaning the workers' context (see your section \"Cleaning the workers' context\")."
  else msg="$msg Clean the workers' context only if the user asks you to."; fi
  [ -n "$key" ] && msg="$msg This worktree is linked to the Jira ticket $key${url:+ ($url)}: read it with Jira and use it as the starting point for planning."
  if [ "$resume" = 1 ]; then
    msg="$msg WARNING: this workspace is being RESUMED after a restart. The team's previous terminals died and the handles above are new. Before talking to the user, follow the section \"Resuming a workspace after a restart\" of your prompt: recover the Run, the tasks, the latest communications and the state of the code, and give them a summary. Start there."
  elif [ "$resume" = 2 ]; then
    msg="$msg WARNING: you are BACK after a restart, with your previous conversation. Every terminal of the team was reopened and the handles above are the new ones; the dispatches that were in flight point to terminals that no longer exist. Before talking to the user, follow the section \"Coming back with your memory\" of your prompt. Start there."
  else
    msg="$msg Start with the startup."
  fi
  printf '%s' "$msg"
}
# A role's parameters (defaults.params + roles.<role>.params) as "k=v, k=v"
params_of() { jq -r --arg r "$2" '((.defaults.params // {}) * (.roles[$r].params // {})) | to_entries | map("\(.key)=\(.value)") | join(", ")' "$1"; }
# A role's extra instructions for this worktree only (the Planner saves them with its skill): <git dir>/orca-roles.notes/<role>.md
notes_file() { local gd; gd="$(git rev-parse --git-dir 2>/dev/null)" || return 0; echo "$(cd "$gd" && pwd)/orca-roles.notes/$1.md"; }
# A worker's scratch folder: fixed per worktree and role, OUTSIDE the worktree ($KIT/tmp/<project>-<hash of the git dir>/<role>).
# The agents reuse it and never delete anything in it; the kit never empties it. It is outside the worktree because
# jest, vitest and eslint collect copies of the project that live inside it and none honors .gitignore.  scratch_dir <role>
scratch_dir() {
  local gd h proj role="${1:-}"
  [ -n "$role" ] || return 1
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || gd="$(pwd -P)"
  h="$(printf '%s' "$gd" | { shasum 2>/dev/null || sha1sum 2>/dev/null || cksum; } | cut -d' ' -f1 | cut -c1-10)"
  proj="$(project_name . | tr -c 'A-Za-z0-9._\n-' '_')"; role="$(printf '%s' "$role" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "$h" ] && [ -n "$proj" ] || return 1
  printf '%s' "$KIT/tmp/$proj-$h/$role"
}
# A worker's message when its tab was reopened with its previous conversation after a restart.  worker_back_msg <config> <role> <handle>
worker_back_msg() {
  printf '%s' "You are back after a restart of the computer or of Orca, with your previous conversation; your role and its instructions still apply. Your terminal handle is now $3. Whatever task you were doing was interrupted and its dispatch is gone: do not continue it on your own. Look at your worktree (git status, git diff --stat) to remember what you had already changed, and wait for the Planner to send it again. If you had no task, stay idle. Reply only with one line saying whether you had a task in progress and what it was."
}
# A worker's startup message.  worker_msg <config> <role>
# If the role has instructions for this worktree, they go inside the message: that way they survive context cleanup.
# Agents other than Claude are also told to run Orca's commands in the foreground: an Antigravity worker ran its worker_done as a
# background subagent task that never finished, so Orca never got its report.
worker_msg() {
  local p n notes="" fg=""; p="$(params_of "$1" "$2")"; p="${p:+$p, }scratchDir=$(scratch_dir "$2")"; n="$(notes_file "$2")"
  case "$(rstr "$1" "$2" agent)" in claude|"") ;; *) fg=" Run every orca orchestration command (and its CLI under any other name) in the foreground, as a direct shell command, and wait for it to finish: never as a background task or through a subagent, or Orca will not get your report.";; esac
  [ -n "$n" ] && [ -s "$n" ] && notes=" Additional instructions for this worktree, which take precedence over your prompt if they conflict: $(tr '\n' ' ' < "$n" | sed 's/  */ /g; s/ $//')"
  printf '%s' "Read $KIT/prompts/common-workers.md and $(prompt_of "$1" "$2") and adopt that role from now on. Follow its instructions to the letter.${p:+ Configuration parameters: $p.}$fg$notes"
}
# A path with ~, {kit} or {home} expanded
expand_path() { local p="${1/#\~/$HOME}"; p="${p//\{kit\}/$KIT}"; printf '%s' "${p//\{home\}/$HOME}"; }
# Command that opens a new conversation in a role's agent (the clearCommand field, or the agent's own)
clear_command() {
  local c; c="$(rstr "$1" "$2" clearCommand)"
  if [ -n "$c" ]; then echo "$c"; return; fi
  case "$(rstr "$1" "$2" agent)" in claude|"") echo "/clear";; codex) echo "/new";; *) ;; esac
}
# A role's MCP servers as a {"mcpServers": {...}} file (the format of Claude Code, Cursor and Gemini CLI).  mcp_file <config> <role>
# The placeholders {worktree}, {project}, {evidenceDir}, {browserState}, {kit} and {home} are expanded in the servers' args, env and url
# (values from role_context; if it was not called, the worktree is the current directory).
mcp_file() {
  jq --arg r "$2" \
     --arg worktree "${ORCA_ROLES_WORKTREE:-$PWD}" --arg project "${ORCA_ROLES_PROJECT:-$(basename "$PWD")}" \
     --arg evidenceDir "${ORCA_ROLES_EVIDENCE_DIR:-qa-evidence}" --arg browserState "${ORCA_ROLES_BROWSER_STATE:-$KIT/browser/default.json}" \
     --arg kit "$KIT" --arg home "$HOME" '
    ((.roles[$r].mcp) // (.defaults.mcp) // []) as $names | (.mcpServers // {}) as $s
    | (if ($names | type) == "array" then $names else [] end) as $names
    | {mcpServers: ([$names[] | select($s[.] != null) | {(.): $s[.]}] | add // {})}
    | walk(if type == "string" then
        gsub("\\{worktree\\}"; $worktree) | gsub("\\{project\\}"; $project) | gsub("\\{evidenceDir\\}"; $evidenceDir)
        | gsub("\\{browserState\\}"; $browserState) | gsub("\\{kit\\}"; $kit) | gsub("\\{home\\}"; $home)
      else . end)' "$1"
}
# The same servers as Codex -c overrides (mcp_servers.<name>.<field>=<TOML value>), one per line.  codex_mcp_overrides <mcp file>
codex_mcp_overrides() {
  jq -r '.mcpServers | to_entries[] | .key as $n | .value
    | (if .command then "mcp_servers.\($n).command=\(.command | @json)" else empty end),
      (if .command and .args then "mcp_servers.\($n).args=\(.args | @json)" else empty end),
      (if .url then "mcp_servers.\($n).url=\(.url | @json)" else empty end),
      (if .env then "mcp_servers.\($n).env={" + ([.env | to_entries[] | "\(.key) = \(.value | @json)"] | join(", ")) + "}" else empty end)' "$1"
}
# Project name: the main repo's folder (not the worktree's); if it is not a repo, the given folder.  project_name <folder>
project_name() {
  local common
  if common="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)"; then
    common="$(cd "$1" && cd "$common" && pwd)"; basename "$(dirname "$common")"
  else basename "$(cd "$1" && pwd)"; fi
}
# A role's context for the mcpServers placeholders; exports ORCA_ROLES_WORKTREE/PROJECT/EVIDENCE_DIR/BROWSER_STATE.  role_context <config> <role> <worktree>
role_context() {
  ORCA_ROLES_WORKTREE="$(cd "$3" && pwd)"
  ORCA_ROLES_PROJECT="$(project_name "$3")"
  ORCA_ROLES_EVIDENCE_DIR="$(jq -r --arg r "$2" '.roles[$r].params.evidenceDir // .roles["e2e-tester"].params.evidenceDir // .defaults.params.evidenceDir // "qa-evidence"' "$1")"
  ORCA_ROLES_BROWSER_STATE="$KIT/browser/$ORCA_ROLES_PROJECT.json"
  export ORCA_ROLES_WORKTREE ORCA_ROLES_PROJECT ORCA_ROLES_EVIDENCE_DIR ORCA_ROLES_BROWSER_STATE
}
# Creates an empty browser state if none exists (Playwright accepts {"cookies":[],"origins":[]}); browser-login.sh fills it.
ensure_browser_state() { [ -f "$1" ] || { mkdir -p "$(dirname "$1")"; echo '{"cookies":[],"origins":[]}' > "$1"; }; }
# The final target of a path, following symlinks (relative, chains, other folders; dangling links too) as an absolute physical path.
# No 'readlink -f' (macOS lacks it); 1 on a link loop or a missing folder. The path is handed to the kernel as it is (a ".." after a
# linked folder means the folder's real parent) and the last folder is entered with cd -P.  resolve_target <path>
resolve_target() {
  local p="$1" dir n=0 l
  while [ -L "$p" ]; do
    n=$((n+1)); [ "$n" -le 40 ] || return 1
    l="$(readlink "$p")" || return 1
    case "$l" in /*) p="$l";; *) p="$(dirname "$p")/$l";; esac
  done
  dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "${dir%/}" "$(basename "$p")"
}
# A file's permission bits in octal (GNU stat, then BSD stat); empty if they cannot be read.  mode_of <file>
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
# Edits a JSON file the user or other programs also write (~/.claude.json holds the user's account and Claude Code sessions rewrite it),
# applying a jq filter ($dir is available in it) with care.  safe_json_edit <file> <jq filter> <dir> [lock path]
#  - the new content goes to a temp file in the TARGET's folder (rename is atomic only on one filesystem; if the file is a
#    link, the target is what is replaced and the link stays). mktemp makes it 0600; the original mode is applied AFTER writing it
#    (a 400 original would block the write), so nobody else can read it at any moment;
#  - the optional lock is a directory taken with mkdir; Claude Code locks "<path it was given>.lock", i.e. the link's path, not the
#    target's, so that is the path to pass. A lock we did not create is never removed;
#  - the lock can be ignored (Claude Code writes without it if it stays busy), so right before the rename the file is compared with
#    what was read: if it changed, we start over once; if it changed again, nothing is written.
# The filter must print exactly one JSON object (the whole, modified file); anything else (nothing, several values, an array, null...)
# counts as a failure and nothing is written.
# Never fatal. Exit status: 0 edited; 3 nothing to do (missing file, not a regular file, or the filter changes nothing: it is not
# rewritten); 2 the file kept changing; 1 it could not be read or written (invalid JSON or filter, no permission...). In 1 and 2 the
# original is left as it was and the temp and our lock are removed.
# Test hook: ORCA_ROLES_TRUST_HOOK=<command> runs (in a bash -c) after the temp is written and before the comparison, to change the file
# at that moment and reproduce the race. Inert when unset.
safe_json_edit() (
  link="$1"; filter="$2"; dir="$3"; lock="${4:-}"; got=0; tmp=""; status=1
  [ -e "$link" ] || exit 3
  f="$(resolve_target "$link")" && [ -f "$f" ] || exit 3
  cur="$(jq -S -c . "$f" 2>/dev/null)"
  [ -z "$cur" ] || [ "$cur" != "$(jq -S -c --arg dir "$dir" "$filter" "$f" 2>/dev/null)" ] || exit 3
  cleanup() { [ -n "$tmp" ] && rm -f "$tmp"; [ "$got" = 1 ] && rmdir "$lock" 2>/dev/null; return 0; }   # only the lock we created
  trap cleanup EXIT; trap 'exit 1' INT TERM HUP
  if [ -n "$lock" ]; then
    for _ in $(seq 1 20); do mkdir "$lock" 2>/dev/null && { got=1; break; }; sleep 0.25; done
    [ "$got" = 1 ] || echo "Note: $lock is held by another process; continuing without it." >&2
  fi
  b="$(basename "$f")"
  if tmp="$(mktemp "$(dirname "$f")/.${b#.}.orca-roles.XXXXXX" 2>/dev/null)"; then
    for _ in 1 2; do
      status=1
      chmod 600 "$tmp" || break
      orig="$(cat "$f")" || break
      printf '%s\n' "$orig" | jq --arg dir "$dir" "$filter" > "$tmp" 2>/dev/null || break
      jq -e -s 'length == 1 and (.[0] | type) == "object"' "$tmp" >/dev/null 2>&1 || break   # the filter must return the whole object, once
      if [ "$(printf '%s\n' "$orig" | jq -S -c . 2>/dev/null)" = "$(jq -S -c . "$tmp" 2>/dev/null)" ]; then status=3; break; fi
      mode="$(mode_of "$f")"
      if [ -n "$mode" ] && [ "$mode" != 600 ]; then chmod "$mode" "$tmp" || break; fi
      [ -n "${ORCA_ROLES_TRUST_HOOK:-}" ] && { bash -c "$ORCA_ROLES_TRUST_HOOK" || true; }
      if [ "$(cat "$f" 2>/dev/null)" = "$orig" ]; then
        mv -f "$tmp" "$f" && status=0
        break
      fi
      status=2
    done
  fi
  exit "$status"
)
# Claude Code asks "Do you trust the files in this folder?" the first time it starts in a folder, and a tab stuck in that dialog never
# gets its role. Registering the kit in the project is that answer, so the worktree is marked as trusted before the agents start.
# Never fatal: on a failure ~/.claude.json is left as it was and a warning is printed.
trust_folder() {
  local link="$HOME/.claude.json" d rc=0; d="$(pwd -P)"
  safe_json_edit "$link" '.projects[$dir] = ((.projects[$dir] // {}) + {hasTrustDialogAccepted: true})' "$d" "$link.lock" || rc=$?
  case "$rc" in
    0) echo "Marked $d as trusted for Claude Code, so the trust dialog does not stop the agents.";;
    1|2) echo "Warning: could not mark $d as trusted for Claude Code ($([ "$rc" = 2 ] && echo 'the file kept changing' || echo 'it could not be read or written')); $link was left untouched and the agent will show the trust dialog." >&2;;
  esac
  return 0
}
# The trust of the custom agents (role field "trust": {"file": ..., "jq": "<filter using $dir>"}): applies it to each enabled custom
# role that defines it, once per distinct file and filter, with $dir = this worktree. Never fatal.  trust_custom_roles <config> <roles>
trust_custom_roles() {
  local cfg="$1" id t file filt d seen="" rc
  d="$(pwd -P)"
  for id in $2; do
    [ "$(rstr "$cfg" "$id" agent)" = custom ] || continue
    t="$(rcfg "$cfg" "$id" trust)"; [ -n "$t" ] || continue
    file="$(printf '%s' "$t" | jq -r '.file // empty' 2>/dev/null)"; filt="$(printf '%s' "$t" | jq -r '.jq // empty' 2>/dev/null)"
    [ -n "$file" ] && [ -n "$filt" ] || { echo "Warning: the trust of role $id needs both 'file' and 'jq'; ignored." >&2; continue; }
    file="$(expand_path "$file")"
    printf '%s\n' "$seen" | grep -qxF "$file|$filt" && continue
    seen="$seen$file|$filt"$'\n'
    rc=0; safe_json_edit "$file" "$filt" "$d" || rc=$?
    case "$rc" in
      0) echo "Marked $d as trusted in $file (role $id).";;
      1|2) echo "Warning: could not mark $d as trusted in $file (role $id; $([ "$rc" = 2 ] && echo 'the file kept changing' || echo 'invalid file or filter, or no permission')); the file was left untouched." >&2;;
    esac
  done
  return 0
}
