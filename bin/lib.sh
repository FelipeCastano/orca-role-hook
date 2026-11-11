# shellcheck shell=bash
# Shared functions. Requires jq. Compatible with bash 3.2 (macOS) and with GNU/BSD tools.
KIT="${KIT:-$HOME/.orca-roles}"
# "KIT=<path> " to put in front of a command that runs later in another process (a tab, a message) when this kit is not the
# installed one, so that process uses this kit too; empty for the installed kit (same folder, even through a link), so those
# commands stay as they always were.
kit_env() {
  [ "$KIT" = "$HOME/.orca-roles" ] && return 0
  [ -d "$KIT" ] && [ "$(cd "$KIT" && pwd -P)" = "$(cd "$HOME/.orca-roles" 2>/dev/null && pwd -P)" ] && return 0
  printf 'KIT=%q ' "$KIT"
}

# Orca's CLI is not always called 'orca': in the WSL terminals Orca manages on Windows it is $ORCA_CLI_COMMAND
# (e.g. orca-ide). If 'orca' is not on the PATH but orca-ide is found, the $KIT/shim/orca wrapper is created and
# prepended to the PATH: the kit's scripts, the prompts and the agents (which inherit the PATH) keep using 'orca'.
# The absolute path of orca-ide: $ORCA_CLI_COMMAND, else $ORCA_WSL_CLI_DIR/orca-ide, else the target the shim recorded; nothing and 1 if none exists.
orca_ide_path() {
  local c="${ORCA_CLI_COMMAND:-}" p line
  if [ -n "$c" ] && [ "$c" != orca ]; then
    p="$(command -v "$c" 2>/dev/null)" || p=""
    case "$p" in /*) [ -x "$p" ] && { printf '%s\n' "$p"; return 0; };; esac
  fi
  if [ -n "${ORCA_WSL_CLI_DIR:-}" ] && [ -x "$ORCA_WSL_CLI_DIR/orca-ide" ]; then printf '%s\n' "$ORCA_WSL_CLI_DIR/orca-ide"; return 0; fi
  if [ -f "$KIT/shim/orca" ]; then
    line="$(grep -m1 '^t=' "$KIT/shim/orca" 2>/dev/null)" || return 1
    p="$( eval "$line" 2>/dev/null; printf '%s' "${t:-}" )"
    [ -n "$p" ] && [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  fi
  return 1
}
# Whether this is WSL (the kernel says Microsoft and wslpath exists).
is_wsl() {
  grep -qi microsoft "${ORCA_ROLES_PROC_VERSION:-/proc/version}" 2>/dev/null && command -v wslpath >/dev/null 2>&1
}
# Orca's "Nested worker depth" (nestedWorkerMaxDepth) as Orca resolves it: an integer >= 1, or nothing when it cannot be read (WSL, no profile, no sqlite3).  orca_nested_depth
orca_nested_depth() {
  local d id p a="" v u
  is_wsl && return 0
  d="${ORCA_USER_DATA_PATH:-}"
  if [ -z "$d" ]; then case "$OSTYPE" in darwin*) d="$HOME/Library/Application Support/orca";; esac; fi
  [ -n "$d" ] && [ -d "$d" ] || return 0
  id="$(jq -r '.activeProfileId // empty' "$d/orca-profile-index.json" 2>/dev/null)" || return 0
  [ -n "$id" ] || return 0
  p="$d/profiles/$id"
  { IFS= read -r a < "$p/profile-state.db.authority"; } 2>/dev/null || true
  a="${a//[[:space:]]/}"
  if [ "$a" = sqlite ]; then
    command -v sqlite3 >/dev/null 2>&1 || return 0
    u="$p/profile-state.db"; u="${u//%/%25}"; u="${u//\?/%3f}"; u="${u//#/%23}"
    v="$(bounded_run 5 orca-depth sqlite3 -readonly "file:$u?mode=ro" "select case when typeof(v) in ('integer','real') and v = cast(v as integer) then cast(v as integer) else '' end from (select json_extract(payload,'\$.nestedWorkerMaxDepth') as v from profile_state_documents where domain='settings')" 2>/dev/null)" || return 0
  else
    v="$(jq -r '.settings.nestedWorkerMaxDepth | if type == "number" and . == floor then floor else "" end' "$p/orca-data.json" 2>/dev/null)" || return 0
  fi
  case "$v" in ''|*[!0-9]*|0) v=1;; esac
  printf '%s\n' "$v"
}
orca_shim() {
  local dir="$KIT/shim" tmp ide cur
  cur="$(type -P orca 2>/dev/null)" || cur=""
  [ -z "$cur" ] || [ "$cur" = "$dir/orca" ] || { [ -L "$cur" ] && [ "$(readlink "$cur")" = "$dir/orca" ]; } || return 0   # also a link to the shim (~/.local/bin/orca on WSL)
  if ide="$(orca_ide_path)"; then
    mkdir -p "$dir" && tmp="$(mktemp "$dir/.orca.XXXXXX")" || return 0
    {
      printf '#!/usr/bin/env bash\n'
      printf 't=%q\n' "$ide"
      printf '%s\n' '[ -x "$t" ] || t="${ORCA_WSL_CLI_DIR:+$ORCA_WSL_CLI_DIR/orca-ide}"' '[ -n "$t" ] && [ -x "$t" ] || t=orca-ide' 'exec "$t" "$@"'
    } > "$tmp" && chmod +x "$tmp" || { rm -f "$tmp"; return 0; }
    if cmp -s "$tmp" "$dir/orca" 2>/dev/null; then rm -f "$tmp"; else mv "$tmp" "$dir/orca"; fi
  elif [ ! -e "$dir/orca" ]; then
    return 0
  fi
  case ":$PATH:" in "$dir":*|":$dir:"*) ;; *) PATH="$dir:$PATH"; export PATH;; esac
}
orca_shim

# Kills a process and all its descendants (children first).  kill_tree <pid>
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill -9 "$1" 2>/dev/null; }

# The one timeout sentence.  bounded_msg <label> <secs>
bounded_msg() { printf '%s: no answer in %s s; stopped.\n' "$1" "$2"; }
# Runs a command with a time limit, keeping its stdin, stdout and stderr (redirect the call to change them): bounded_run [--quiet] [--cd <dir>] <secs> <label> <command> [args...].
# Past the limit its process tree is killed, the status is 124, BOUNDED_TIMED is 1 (0 otherwise, so a command's own exit 124 is not a timeout; it does not survive $(...)) and bounded_msg goes to stderr unless --quiet.
# --cd runs an external command in <dir> (a shell function gives 127 and bash's own "not found"; a <dir> that fails gives 1 and cd's own message). <secs> must be a number above 0 (0 means no limit only in orca()): anything else prints a message, returns 2 and runs nothing.
# If no marker can be created in the temp folder the command runs without a limit. If the caller dies, the watchdog still stops the command at the limit and removes the markers.
# shellcheck disable=SC2034  # BOUNDED_TIMED is read by the callers
bounded_run() {
  local quiet=0 dir="" secs label m pid wd s="" rc=0 caller=$$
  BOUNDED_TIMED=0
  while :; do
    case "${1:-}" in
      --quiet) quiet=1; shift;;
      --cd) dir="$2"; shift 2;;
      *) break;;
    esac
  done
  secs="$1"; label="$2"; shift 2
  case "$secs" in
    *[!0-9.]*|*.*.*) rc=2;;
    *[1-9]*) ;;
    *) rc=2;;
  esac
  if [ "$rc" = 2 ]; then echo "bounded_run: bad limit '$secs' for $label" >&2; return 2; fi
  if [ -n "$dir" ]; then ( cd "$dir" && exec "$@" ) <&0 & pid=$!
  else "$@" <&0 & pid=$!; fi
  m="${TMPDIR:-/tmp}/orca-roles-limit.$$.$pid"
  { : > "$m"; } 2>/dev/null || { wait "$pid" 2>/dev/null; return $?; }
  # No signal goes to the watchdog (a trapped TERM can be lost or held until its sleep ends): it writes its sleep's pid to $m.s before it looks for $m, and the caller removes $m before it reads $m.s, so one of the two always kills that sleep
  ( sleep "$secs" & s=$!; echo "$s" > "$m.s" || { kill "$s"; exit 0; }
    if [ ! -e "$m" ]; then kill "$s" 2>/dev/null; exit 0; fi
    wait "$s"
    if [ -e "$m" ] && kill -0 "$pid" 2>/dev/null; then : > "$m.fired"; kill_tree "$pid"; fi
    kill -0 "$caller" 2>/dev/null || rm -f "$m" "$m.fired" "$m.s" ) </dev/null >/dev/null 2>&1 & wd=$!
  wait "$pid" 2>/dev/null || rc=$?
  rm -f "$m"
  if [ ! -e "$m.fired" ]; then
    { read -r s < "$m.s"; } 2>/dev/null || true
    if [ -n "$s" ]; then kill "$s" 2>/dev/null || true; fi
  fi
  wait "$wd" 2>/dev/null || true
  if [ -e "$m.fired" ]; then BOUNDED_TIMED=1; rc=124; [ "$quiet" = 1 ] || bounded_msg "$label" "$secs" >&2; fi
  rm -f "$m.fired" "$m.s"
  return "$rc"
}

# For scripts with a temp folder $T and a limit $TO: runs <command...> with stdout/err in $T/<name>.out/.err and stdin closed. Sets RC and TIMED; returns 0.  bounded <name> <command...>
# shellcheck disable=SC2034  # RC and TIMED are read by the callers
bounded() {
  local i="$1"; shift
  RC=0; bounded_run --quiet "$TO" "$i" "$@" > "$T/$i.out" 2> "$T/$i.err" < /dev/null || RC=$?
  TIMED="$BOUNDED_TIMED"
  return 0
}

# A fixed retry or poll wait of <secs> seconds; ORCA_ROLES_PACE replaces it (tests).
pace() { sleep "${ORCA_ROLES_PACE:-$1}"; }

# Waits until a Claude Code tab is at rest with an empty composer (read as dispatch.sh's coord_ready reads it), so the kit never types over what the
# user is writing.  front_wait_ready <handle> <timeout ms> → 0 ready; 1 the tab never became idle; 2 it stayed idle with text in its composer
front_wait_ready() {
  local end left rc=1
  end=$(( $(date +%s) + ($2 + 999) / 1000 ))
  while :; do
    left=$(( (end - $(date +%s)) * 1000 ))
    [ "$left" -gt 0 ] || return "$rc"
    orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$left" --json >/dev/null 2>&1 || return "$rc"
    pace "${ORCA_ROLES_FRONT_MODEL_SETTLE:-2}"
    if orca terminal show --terminal "$1" --json 2>/dev/null | jq -e '(.result.terminal.preview // "") as $p | ($p | contains("[Pasted text") | not) and ($p | split("\n") | any(sub("\\s+$"; "") == "❯"))' >/dev/null 2>&1; then return 0; fi
    rc=2
    pace "${ORCA_ROLES_FRONT_MODEL_RETRY:-2}"
  done
}

# Switches the Claude Code session in a tab to another model with /model, and puts back the user's saved default model if Claude Code saved
# the new one there (its /model may save it "as your default for new sessions" in the user settings).  front_set_model <handle> <model> <timeout ms>
front_set_model() {
  local rc=0 S before after
  front_wait_ready "$1" "$3" || rc=$?
  case "$rc" in
    0) ;;
    1) echo "The tab $1 did not become idle; its model was not changed."; return 1;;
    *) echo "The tab $1 was in use (text in its composer); its model was not changed."; return 1;;
  esac
  S="${ORCA_ROLES_CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
  if [ -f "$S" ]; then before="$(jq -c 'if type == "object" and has("model") then {v: .model} else {} end' "$S" 2>/dev/null)"
  else before=missing; fi
  orca terminal send --terminal "$1" --text "/model $2" --enter --json >/dev/null 2>&1
  orca terminal wait --terminal "$1" --for tui-idle --timeout-ms "$3" --json >/dev/null 2>&1 || true
  if [ -f "$S" ]; then after="$(jq -c 'if type == "object" and has("model") then {v: .model} else {} end' "$S" 2>/dev/null)"
  else after=missing; fi
  if [ -n "$before" ] && [ "$after" != "$before" ]; then
    rc=0
    if [ "$before" = missing ] || [ "$before" = '{}' ]; then safe_json_edit "$S" 'del(.model)' "" "$S.lock" || rc=$?
    else safe_json_edit "$S" '.model = ($dir | fromjson | .v)' "$before" "$S.lock" || rc=$?; fi
    [ "$rc" != 0 ] || echo "Put back the default model in $S (Claude Code had saved $2 there)."
  fi
  echo "The tab $1 now runs $2."
  return 0
}

# Every orca call of the kit's scripts has a time limit: $ORCA_ROLES_CLI_TIMEOUT s (60; 0 = none), or the call's --timeout-ms (rounded up to s) + 60.
# `terminal close` has its own, $ORCA_ROLES_CLOSE_TIMEOUT s (15; 0 = none). A value that is not a whole number is ignored.
orca() {
  local lim="${ORCA_ROLES_CLI_TIMEOUT:-}" a prev="" close="${ORCA_ROLES_CLOSE_TIMEOUT:-}"
  case "$lim" in ''|*[!0-9]*) lim=60;; esac
  case "$close" in ''|*[!0-9]*) close=15;; esac
  if [ "$lim" = 0 ] || { [ "${1:-} ${2:-}" = "terminal close" ] && [ "$close" = 0 ]; }; then   # by path: bash 3.2 ends a background job with set -e at a failing "command orca" inside this function
    a="$(type -P orca)" || return 127
    "$a" "$@"; return
  fi
  [ "${1:-} ${2:-}" = "terminal close" ] && lim="$close"   # on WSL a tab closing itself never gets the answer
  for a in "$@"; do
    if [ "$prev" = --timeout-ms ]; then case "$a" in ''|*[!0-9]*) ;; *) lim=$(( (a + 999) / 1000 + 60 ));; esac; fi
    prev="$a"
  done
  bounded_run "$lim" "orca ${1:-} ${2:-} (no answer from Orca)" command orca "$@"
}

# After a close that got no answer (124): returns 0 if the tab is gone (Orca says its handle is stale), else tells it was not confirmed and returns 1.
close_unconfirmed() {  # close_unconfirmed <handle> <title>
  local js
  js="$(orca terminal show --terminal "$1" --json 2>/dev/null)"
  [ "$(printf '%s' "$js" | jq -r '.error.code // empty' 2>/dev/null)" = terminal_handle_stale ] && return 0
  echo "Orca did not confirm closing the tab of $2 ($1)."; return 1
}

# Fills the git answers of the current directory (one git run); stores nothing when git fails or answers other than four lines.  git_here_init
git_here_init() {
  local out nl
  GH_PWD=""
  out="$(git rev-parse --show-toplevel --git-dir --git-common-dir --absolute-git-dir 2>/dev/null)" || return 0
  nl="${out//[!$'\n']/}"; [ "${#nl}" = 3 ] || return 0
  { IFS= read -r GH_TOP; IFS= read -r GH_GD; IFS= read -r GH_COMMON; IFS= read -r GH_ABS; } <<< "$out"
  GH_PWD="$PWD"
}
# What `git rev-parse --<field>` prints in the current directory (toplevel, git-dir, common-dir or absolute-git-dir), answered from one git run per directory; same status as git.  git_here <field>
git_here() {
  case "$1" in toplevel|git-dir|common-dir|absolute-git-dir) ;; *) return 2;; esac
  [ "${GH_PWD:-}" = "$PWD" ] || git_here_init
  if [ "${GH_PWD:-}" = "$PWD" ]; then
    case "$1" in
      toplevel) printf '%s\n' "$GH_TOP";; git-dir) printf '%s\n' "$GH_GD";;
      common-dir) printf '%s\n' "$GH_COMMON";; *) printf '%s\n' "$GH_ABS";;
    esac
    return 0
  fi
  case "$1" in
    toplevel) git rev-parse --show-toplevel 2>/dev/null;; git-dir) git rev-parse --git-dir 2>/dev/null;;
    common-dir) git rev-parse --git-common-dir 2>/dev/null;; *) git rev-parse --absolute-git-dir 2>/dev/null;;
  esac
}

# OpenCode role sessions. agent.sh starts an OpenCode role with `--session <id>` and saves the id, and the folder it runs in, in the team's git
# dir; the kit deletes that session when the role is closed or replaced (closing the tab ends a turn of the role's private server; the
# session stays in OpenCode's store until it is deleted).
# File with a role's saved session id.  oc_session_file <role> [<git dir>]  (default: the git dir of the current directory)
oc_session_file() {
  local gd="${2:-}"
  [ -n "$gd" ] || gd="$(team_git_dir)" || return 1
  gd="$(cd "$gd" 2>/dev/null && pwd)" || return 1
  printf '%s/orca-roles-opencode-%s.session' "$gd" "$1"
}
# File with a role's OpenCode configuration (opencode-prepare.sh writes it, agent.sh passes it as OPENCODE_CONFIG).  oc_config_file <role> [<git dir>]
oc_config_file() {
  local gd="${2:-}"
  [ -n "$gd" ] || gd="$(team_git_dir)" || return 1
  gd="$(cd "$gd" 2>/dev/null && pwd -P)" || return 1
  printf '%s/orca-roles-opencode-%s.json' "$gd" "$1"
}
# Whether the kit's opencode calls must keep the project's own OpenCode configuration and plugins off: settings.trust "never" in
# $ORCA_ROLES_CONFIG (when it is a file), else in the team's saved configuration. Only a private server honours the switch.  oc_untrusted
oc_untrusted() {
  local c="${ORCA_ROLES_CONFIG:-}" gd
  if [ -z "$c" ] || [ ! -f "$c" ]; then gd="$(team_git_dir)" || return 1; c="$gd/orca-roles.config.json"; [ -f "$c" ] || return 1; fi
  [ "$(trust_of "$c" 2>/dev/null)" = never ]
}
# Runs `opencode <args>` in the current worktree (OpenCode scopes sessions to the directory), stdin closed, output in <file>, cut after
# <seconds>.  oc_bounded <seconds> <file> <args...>   Sets OC_RC (124 when it was cut); returns 0.
# Under settings.trust "never" (oc_untrusted) it runs with a private server and OPENCODE_DISABLE_PROJECT_CONFIG=1.
oc_bounded() {
  local to="$1" out="$2" wt; shift 2
  wt="$(git_here toplevel)" && wt="$(cd "$wt" 2>/dev/null && pwd -P)" || wt="$(pwd -P)"
  OC_RC=0
  if oc_untrusted; then bounded_run --quiet --cd "$wt" "$to" opencode env OPENCODE_DISABLE_PROJECT_CONFIG=1 opencode "$@" --standalone > "$out" 2>&1 < /dev/null || OC_RC=$?
  else bounded_run --quiet --cd "$wt" "$to" opencode opencode "$@" > "$out" 2>&1 < /dev/null || OC_RC=$?; fi
  return 0
}
# Best-effort delete of one OpenCode session of this worktree (it interrupts a running turn).  oc_delete_id <id>
# Never fails; prints one line when it could not. ORCA_ROLES_OC_DELETE_TIMEOUT: seconds before it is cut (default 20).
oc_delete_id() {
  local tmp to="${ORCA_ROLES_OC_DELETE_TIMEOUT:-20}"
  case "$to" in ''|*[!0-9]*|0*) to=20;; esac
  [ -n "$1" ] || return 0
  command -v opencode >/dev/null 2>&1 || { echo "Could not delete OpenCode session $1: opencode is not in the PATH."; return 0; }
  tmp="$(mktemp)" || return 0
  oc_bounded "$to" "$tmp" session delete "$1"
  if [ "$OC_RC" = 124 ]; then echo "Could not delete OpenCode session $1: $(bounded_msg opencode "$to")"
  elif [ "$OC_RC" != 0 ]; then echo "Could not delete OpenCode session $1: opencode exited with $OC_RC."; fi
  rm -f "$tmp"; return 0
}
# After /new in an OpenCode tab: saves the newest session of the role's folder (line 2 of its session file, else this worktree) created since <ms epoch> as the role's session and deletes the
# old one; with none found it says so and deletes the old one anyway.  oc_retrack <role> <since ms> [<git dir>]
oc_retrack() {
  local f old new tmp wt dir
  f="$(oc_session_file "$1" "${3:-}")" || return 0
  [ -f "$f" ] || return 0
  old="$(head -1 "$f" 2>/dev/null)"; new=""; dir="$(sed -n 2p "$f" 2>/dev/null)"
  if [ -n "$dir" ]; then wt="$dir"
  else wt="$(git_here toplevel)" && wt="$(cd "$wt" 2>/dev/null && pwd -P)" || wt="$(pwd -P)"; fi
  if command -v opencode >/dev/null 2>&1 && tmp="$(mktemp)"; then
    oc_bounded 20 "$tmp" session list --format json
    [ "$OC_RC" != 0 ] || new="$(jq -r --arg d "$wt" --argjson s "$2" '[.[]? | select(.directory == $d and (.created // 0) >= $s)] | sort_by(.created) | reverse | .[0].id // empty' "$tmp" 2>/dev/null)"
    rm -f "$tmp"
  fi
  if [ -z "$new" ]; then
    echo "Could not track the new OpenCode session of $1 after /new; its old session is deleted and the role has no tracked session."
    oc_session_delete "$1" "${3:-}"; return 0
  fi
  [ "$new" != "$old" ] || return 0
  { printf '%s\n' "$new"; [ -z "$dir" ] || printf '%s\n' "$dir"; } > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
  oc_delete_id "$old"; return 0
}
# Deletes the session saved for a role and forgets the file.  oc_session_delete <role> [<git dir>]
oc_session_delete() {
  local f id
  f="$(oc_session_file "$1" "${2:-}")" || return 0
  [ -f "$f" ] || return 0
  id="$(head -1 "$f" 2>/dev/null)"
  oc_delete_id "$id"
  rm -f "$f"; return 0
}

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
  local top common main tcmd=(git -C "$1" rev-parse --show-toplevel) ccmd=(git rev-parse --git-common-dir)
  case "$1" in .|"$PWD") tcmd=(git_here toplevel); ccmd=(git_here common-dir);; esac
  top="$("${tcmd[@]}" 2>/dev/null)" || return 0
  [ -f "$top/.orca-roles.json" ] && { echo "$top/.orca-roles.json"; return 0; }
  common="$(cd "$1" && "${ccmd[@]}" 2>/dev/null)" || return 0
  main="$(cd "$1" && cd "$common/.." && pwd)"
  [ -f "$main/.orca-roles.json" ] && echo "$main/.orca-roles.json"
  return 0
}
# A role's value, inheriting from defaults:  rcfg <config> <role> <field>
rcfg() { jq -c --arg r "$2" --arg k "$3" '(.roles[$r][$k]) // (.defaults[$k]) // empty' "$1"; }
rstr() { jq -r --arg r "$2" --arg k "$3" '(.roles[$r][$k]) // (.defaults[$k]) // empty' "$1"; }
# A role's model in a mode (default: the configuration's saved mode): roles.<role>.modelByMode.<mode> when it is a non-empty string, else the role's model (or defaults.model).  role_model <config> <role> [<mode>]
role_model() { local m="${3:-}"; [ -n "$m" ] || m="$(mode_of --saved "$1" 2>/dev/null)" || m=programmer; jq -r --arg r "$2" --arg m "$m" '(.roles[$r].modelByMode // null) as $b | if ($b | type) == "object" and ($b[$m] | type) == "string" and $b[$m] != "" then $b[$m] else ((.roles[$r].model) // (.defaults.model) // empty) end' "$1"; }
# The error text (ERE) a role's agent prints when its model does not exist; empty = no detection for that role.  model_error_regex <config> <role> <model>
# claude: Claude Code's own texts; codex: the API error naming the model; custom and opencode: the role's modelError with {model} as the
# escaped model id. For opencode the screen check only runs with the role's own modelError: `mini` prints nothing for a missing model,
# so the kickoff looks the model up in `opencode models` instead (see oc_model_state in kickoff.sh).
model_error_regex() {
  local agent esc; [ -n "$3" ] || return 0
  agent="$(rstr "$1" "$2" agent)"; esc="$(regex_escape "$3")"
  case "${agent:-claude}" in
    claude) printf '%s\n' "There's an issue with the selected model|The model [^ ]+ is not available on your|API Error \([^)]+\): [^.]*[Mm]odel [Ii][Dd]";;
    codex) printf '%s\n' "(unexpected status|ERROR:)[^E]{0,200}${esc}[^E]{0,200}(does not exist|not supported|model_not_found)";;
    custom|opencode) jq -r --arg r "$2" --arg m "$esc" '(.roles[$r].modelError // .defaults.modelError // empty) | gsub("\\{model\\}"; $m)' "$1" 2>/dev/null;;
  esac
}
# A setting's value as text, or the default when it is absent or null (false is a value: jq's // would drop it).
setting() { jq -r --arg k "$2" --arg d "$3" '(if (.settings | type) == "object" and (.settings | has($k)) and .settings[$k] != null then .settings[$k] else $d end) | tostring' "$1"; }
# The kit's modes: fixed, not configurable. A mode is available when its folder has a local coordinator prompt.
MODE_IDS="programmer pr-reviewer academic-research quick"
MODES_JSON='["programmer","pr-reviewer","academic-research","quick"]'
MODE_LIST="programmer, pr-reviewer, academic-research, quick"
# Why a mode id is unusable (empty output if it is fine): the match is exact against the list, so nothing like ../x or a path reaches a prompt path.
mode_error() {  # <id>
  local m
  for m in $MODE_IDS; do
    if [ "$m" = "$1" ]; then
      [ -f "$KIT/prompts/$1/local-coordinator.md" ] || echo "mode '$1' is not available yet"
      return 0
    fi
  done
  [ "$1" = academic-writer ] && { echo "mode 'academic-writer' was renamed: use academic-research"; return 0; }
  echo "unknown mode '$1' (modes: $MODE_LIST)"
}
# The effective mode of a configuration (settings.mode, "programmer" if unset); 1 with the reason on stderr if it is invalid or unavailable.  mode_of [--saved] <config>
mode_of() {
  local m e saved=0
  [ "${1:-}" = --saved ] && { saved=1; shift; }
  m="$(jq -j '(if has("settings") then .settings else {} end) | if type != "object" then error("settings must be an object") else (if has("mode") then .mode else "programmer" end) end | if type == "string" then . else tojson end' "$1" 2>/dev/null; rc=$?; printf x; exit $rc)" \
    || { echo "invalid settings in the configuration: settings must be an object" >&2; return 1; }
  m="${m%x}"   # the sentinel keeps a trailing newline in the id, which then fails the exact match
  [ "$saved" = 1 ] && [ "$m" = academic-writer ] && m=academic-research   # configs saved by kits before v1.4
  e="$(mode_error "$m")"
  [ -z "$e" ] || { echo "$e" >&2; return 1; }
  printf '%s\n' "$m"
}
# The phase of a configuration (settings.phase, "experiment" if unset): academic-research only.  phase_of <config>
phase_of() { jq -r '(.settings // {}) | .phase // "experiment" | tostring' "$1" 2>/dev/null || echo experiment; }
# Enabled roles of the configuration's mode, in order; the mode's front role always runs. A role without "modes" belongs to programmer only.
# In academic-research a role with "phases" also needs the current phase in it; in the other modes "phases" is ignored.
enabled_roles() {
  local m p f; m="$(mode_of --saved "$1")" || return 1
  p="$(phase_of "$1")"; f="$(front_role "$m")"
  jq -r --arg m "$m" --arg p "$p" --arg f "$f" '.roles | to_entries[]
    | select(.key == $f or (.value.enabled != false and ((.value.modes // ["programmer"]) | if . == "all" then true elif type == "array" then (index($m) != null) else false end)
        and ($m != "academic-research" or (.value | has("phases") | not) or (.value.phases | type == "array" and index($p) != null))))
    | .key' "$1"
}
# The enabled roles that can start: a worker whose prompt file for the mode is missing is skipped with a warning.  launchable_roles <config>
launchable_roles() {
  local id m f fr; m="$(mode_of --saved "$1")" || return 1
  fr="$(front_role "$m")"
  for id in $(enabled_roles "$1"); do
    f="$(prompt_of "$1" "$id")"
    if [ "$id" != "$fr" ] && [ ! -f "$f" ]; then echo "Warning: role $id is skipped: it has no prompt for mode $m (expected $f)." >&2; continue; fi
    echo "$id"
  done
}
# The agents a role can run hidden on: each needs a headless branch in agent.sh and an adapter in hidden-role.sh. Only claude has been measured.
HIDDEN_AGENTS="claude"
hidden_capable() { case " $HIDDEN_AGENTS " in *" ${1:-claude} "*) return 0;; esac; return 1; }
# When a role's tab opens: start (with the team), first-use (before its first task, then it stays), per-task (before each task, closed after
# its report), per-batch (before its first task of each batch, kept through the batch, closed when the batch closes; per-task in pr-reviewer, which has no batches) or hidden (never a tab: the local coordinator runs it with hidden-role.sh). A role without its own value takes defaults.open (the
# kit ships first-use); none at all, or any other value, = start; the front role and the Planner always start. A hidden value on a role whose
# agent cannot run hidden gives first-use (an explicit one is a config error, see check_config).  open_of <config> <role>
open_of() {
  local v; [ "$2" = "$(front_role "$(mode_of --saved "$1" 2>/dev/null || echo programmer)")" ] && { printf start; return 0; }
  v="$(rstr "$1" "$2" open)"
  case "$v" in
    first-use|per-task) printf '%s' "$v";;
    per-batch) if [ "$(mode_of --saved "$1" 2>/dev/null || echo programmer)" = pr-reviewer ]; then printf per-task; else printf per-batch; fi;;
    hidden) if [ "$2" = planner ]; then printf start; elif hidden_capable "$(rstr "$1" "$2" agent)"; then printf hidden; else printf first-use; fi;;
    *) printf start;;
  esac
}
# max_instances <config> <id>: the role's effective maxInstances (1 unless its open is per-task or per-batch and its agent claude, codex or opencode)
max_instances() {
  jq -r --arg r "$2" '.roles[$r] as $x | if ($x | type) != "object" or ($x | has("instanceOf")) or (($x.maxInstances? // null) | type) != "number" or $x.maxInstances != ($x.maxInstances | floor) then 1
    else (($x.open // .defaults.open // "start") as $o | ($x.agent // .defaults.agent // "claude") as $a
      | if ($o | IN("per-task", "per-batch")) and ($a | IN("claude", "codex", "opencode")) then $x.maxInstances else 1 end) end' "$1" 2>/dev/null || echo 1
}
# The role an instance belongs to (nothing for a role).  instance_base <config> <id>
instance_base() { jq -r --arg i "$2" '.roles[$i].instanceOf // empty' "$1" 2>/dev/null; }
# Writes the entry of instance <role>-<n> in a configuration file: the role's entry without maxInstances, a numbered title and instanceOf.  instance_entry <config file> <role> <n>
instance_entry() {
  jq --arg r "$2" --arg n "$3" '.roles[$r + "-" + $n] = ((.roles[$r] | del(.maxInstances)) + {title: "\(.roles[$r].title // $r) \($n)", instanceOf: $r})' "$1" > "$1.inst.$$" && mv "$1.inst.$$" "$1"
  local rc=$?; rm -f "$1.inst.$$"; return $rc
}
# Rebuilds in a configuration file the entries of the instances that have a saved tab in the state file.  materialize_instances <config file> <state file>
materialize_instances() {
  [ -s "$2" ] || return 0
  local line v id base n
  while IFS= read -r line || [ -n "$line" ]; do
    v="${line%%=*}"; [ -n "${line#*=}" ] || continue
    id="$(printf '%s' "$v" | tr 'A-Z_' 'a-z-')"; base="${id%-*}"; n="${id##*-}"
    [ "$base" != "$id" ] || continue
    case "$n" in ''|*[!0-9]*|0*) continue;; esac
    [ "$n" -ge 2 ] || continue
    jq -e --arg i "$id" --arg b "$base" '(.roles[$i] == null) and ((.roles[$b] | type) == "object") and (.roles[$b].instanceOf == null)' "$1" >/dev/null 2>&1 || continue
    instance_entry "$1" "$base" "$n" || return 1
  done < "$2"
  return 0
}
# "<saved tabs of the role and its instances> <saved instance tabs of the whole team>".  instance_tabs <config> <state file> <role>
instance_tabs() {
  local ids; ids="$(sed -n 's/^\([^=]*\)=..*/\1/p' "$2" 2>/dev/null | tr 'A-Z_' 'a-z-' | jq -R . | jq -s . 2>/dev/null)"; [ -n "$ids" ] || ids='[]'
  jq -r --arg r "$3" --argjson ids "$ids" '. as $c | [$ids[] | select(. == $r or ($c.roles[.].instanceOf? == $r))] as $k | [$ids[] | select($c.roles[.].instanceOf? != null)] as $e | "\($k | length) \($e | length)"' "$1" 2>/dev/null || echo "0 0"
}
# The id of the tab a role opens next: its own when it has none, else <role>-<n> with the lowest free n up to its maxInstances; nothing when none is free.  instance_slot <config> <state file> <role>
instance_slot() {
  local n max; grep -q "^$(var_of "$3")=." "$2" 2>/dev/null || { printf '%s' "$3"; return 0; }
  max="$(max_instances "$1" "$3")"
  for ((n = 2; n <= max; n++)); do
    grep -q "^$(var_of "$3-$n")=." "$2" 2>/dev/null || { printf '%s-%s' "$3" "$n"; return 0; }
  done
}
# "<load1> <cores> <availableMB>" of this machine, each "-" when unreadable (test hook: ORCA_ROLES_HOST_CAPACITY, a command printing the same).  host_capacity
host_capacity() {
  [ -n "${ORCA_ROLES_HOST_CAPACITY:-}" ] && { "$ORCA_ROLES_HOST_CAPACITY"; return 0; }
  local lc mem="" out total pct ps pages l v
  lc="$(python3 -c 'import os; print("%.2f %d" % (os.getloadavg()[0], os.cpu_count() or 1))' 2>/dev/null)" || lc=""
  case "$lc" in *" "*) ;; *) lc="- -";; esac
  case "$(uname -s 2>/dev/null)" in
    Linux) mem="$(awk '/^MemAvailable:/ {print int($2 / 1024); exit}' /proc/meminfo 2>/dev/null)";;
    Darwin)
      out="$(memory_pressure -Q 2>/dev/null)"
      total="$(printf '%s\n' "$out" | awk '/^The system has/ {print $4; exit}')"
      pct="$(printf '%s\n' "$out" | awk '/free percentage/ {print $NF; exit}')"; pct="${pct%\%}"
      case "$total$pct" in ''|*[!0-9]*) total=""; pct="";; esac
      if [ -z "$total" ] || [ -z "$pct" ]; then
        pct="$(sysctl -n kern.memorystatus_level 2>/dev/null)"; total="$(sysctl -n hw.memsize 2>/dev/null)"
        case "$total$pct" in ''|*[!0-9]*) total=""; pct="";; esac
      fi
      if [ -n "$total" ] && [ -n "$pct" ]; then mem=$((total / 1048576 * pct / 100))
      else
        out="$(vm_stat 2>/dev/null)"
        ps="$(printf '%s\n' "$out" | head -1 | sed -n 's/.*page size of \([0-9][0-9]*\).*/\1/p')"
        pages="$(printf '%s\n' "$out" | awk '/^Pages (free|inactive|speculative):/ {v = $NF; sub(/\.$/, "", v); s += v; n++} END {if (n) print s}')"
        case "$ps$pages" in ''|*[!0-9]*) ;; *) mem=$((pages * ps / 1048576));; esac
      fi;;
  esac
  case "$mem" in ''|*[!0-9]*) mem="-";; esac
  printf '%s %s\n' "$lc" "$mem"
}
# A process's start time as one word (ps lstart, spaces as _), or nothing when it is gone: with the pid it names one process, so a reused pid is not taken for it. LC_ALL=C: the supervisor and --status must print it alike
proc_start() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//' | tr -s ' ' '_'; }
proc_is() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$2" != - ] && kill -0 "$1" 2>/dev/null && [ "$(proc_start "$1")" = "$2" ]; }   # proc_is <pid> <start>
# Whether a hidden role has a run in flight: <git dir>/orca-roles-hidden/<role>.pid holds "<agent pid> <agent start> <supervisor pid> <supervisor start> <tag>"
# (while a run starts: "starting - - - <tag>"). Live when either pair names its process (the supervisor counts: the moment between the agent's end and
# its message is not a loss), or when the file is under a minute old (a start in progress, or a write not yet filled).  hidden_live <git dir> <role>
hidden_live() {
  local f="$1/orca-roles-hidden/$2.pid" ap as sp ss
  [ -f "$f" ] || return 1
  read -r ap as sp ss _ < "$f" 2>/dev/null
  proc_is "${ap:-}" "${as:--}" && return 0
  proc_is "${sp:-}" "${ss:--}" && return 0
  [ -n "$(find "$f" -mmin -1 2>/dev/null)" ] && return 0
  return 1
}
# The role id a name (id or title, any case) refers to in a configuration; nothing if there is none.  resolve_role <config> <name>
resolve_role() { jq -r --arg x "$2" '.roles | to_entries[] | select(.key == $x or ((.value.title // .key) | ascii_downcase) == ($x | ascii_downcase)) | .key' "$1" 2>/dev/null | head -1; }
title_of() { jq -r --arg r "$2" '.roles[$r].title // $r' "$1"; }
# The tab title: the role's title plus "(<agent>)", the agent's CLI name. Orca (1.4.239) only dispatches to a tab it recognizes as an
# agent, by its title or its process, and a native Claude Code's process is named after its version: the name in the title is what works.
# tab_title_of <config> <role>
tab_title_of() {
  local t a c w tok="" words=() lt; t="$(title_of "$1" "$2")"; a="$(rstr "$1" "$2" agent)"; a="${a:-claude}"
  if [ "$a" = custom ]; then
    c="$(rstr "$1" "$2" command)"; read -r -a words <<< "$c" || true
    for w in ${words[@]+"${words[@]}"}; do
      case "$w" in *=*) continue;; esac
      w="${w##*/}"; tok="$(lower_ascii "${w%%.*}")"; break
    done
  else
    tok="$(lower_ascii "$a")"
  fi
  [ -n "$tok" ] || { printf '%s\n' "$t"; return 0; }
  lt="$(lower_ascii "$t")"
  case "$lt" in *"($tok)") printf '%s\n' "$t";; *) printf '%s (%s)\n' "$t" "$tok";; esac
}
# The text with A-Z mapped to a-z, no trailing newline; non-ASCII letters are left as they are.  lower_ascii <text>
lower_ascii() {
  local s="$1" u=ABCDEFGHIJKLMNOPQRSTUVWXYZ l=abcdefghijklmnopqrstuvwxyz i
  for ((i = 0; i < 26; i++)); do s="${s//"${u:i:1}"/${l:i:1}}"; done
  printf '%s' "$s"
}
var_of() {
  local s="$1" u=ABCDEFGHIJKLMNOPQRSTUVWXYZ l=abcdefghijklmnopqrstuvwxyz i
  for ((i = 0; i < 26; i++)); do s="${s//"${l:i:1}"/${u:i:1}}"; done
  printf '%s\n' "${s//-/_}"
}
# The role that opens first, owns the Run and talks to the user: the local coordinator, in every mode and while no mode is chosen.  front_role <mode> [<git dir>]
front_role() {
  if [ -n "${2:-}" ] && [ -e "$2/orca-roles.mode-pending" ]; then echo local-coordinator; return 0; fi
  echo local-coordinator
}
front_var() { var_of "$(front_role "$@")"; }
# The front role of a configuration's saved mode in this worktree (or in <git dir>).  front_of <config> [<git dir>]
front_of() {
  local m gd="${2:-}"; m="$(mode_of --saved "$1" 2>/dev/null)" || m=programmer
  [ -n "$gd" ] || gd="$(team_git_dir 2>/dev/null)" || gd=""
  [ -z "$gd" ] || gd="$(cd "$gd" 2>/dev/null && pwd)" || gd=""
  front_role "$m" "$gd"
}
# How messages name a front role.  front_label <role> [cap]
front_label() {
  local l="the Planner"; [ "$1" = local-coordinator ] && l="the local coordinator"
  [ "${2:-}" = cap ] && l="T${l#t}"
  printf '%s' "$l"
}
# The kit's prompts folder for the configuration's mode
prompts_dir_of() { local m; m="$(mode_of --saved "$1" 2>/dev/null)" || return 1; echo "$KIT/prompts/$m"; }
# A role's prompt file: "prompt" as a string (legacy: programmer only) or as {"<mode>": path} (accepts ~, {kit} and {home}), or the mode's prompts/<mode>/<role>.md
prompt_of() {
  local m p b; m="$(mode_of --saved "$1" 2>/dev/null)" || return 1
  b="$(instance_base "$1" "$2")"; b="${b:-$2}"
  p="$(jq -r --arg r "$2" --arg m "$m" '.roles[$r].prompt as $p
    | if ($p | type) == "string" then (if $m == "programmer" then $p else empty end)
      elif ($p | type) == "object" then ($p[$m] // empty | strings) else empty end' "$1")"
  p="$(expand_path "$p")"; echo "${p:-$KIT/prompts/$m/$b.md}"   # accepts ~, {kit} and {home}
}
# Updates a user configuration with the new keys/roles of the default one, without overwriting values or the order of their roles.
# Roles renamed between versions (old id → new id), applied to the user's config, .orca-roles.json and the setup script options.
LEGACY_ROLES='{"visual-tester": "e2e-tester"}'
LEGACY_JQ='def legacy($l): if (.roles? | type) == "object" then .roles |= (to_entries | map(if $l[.key] then .key = $l[.key] | (if .value.title == "Visual-Tester" then .value.title = "E2E-Tester" else . end) else . end) | from_entries) else . end;'
# The playwright MCP entry of the defaults before the kit pinned its own browser stack: a user still on exactly it moves to the new default entry.
OLD_PLAYWRIGHT_MCP='{"command":"npx","args":["-y","@playwright/mcp@latest","--headless","--isolated","--storage-state","{browserState}","--output-dir","{worktree}/{evidenceDir}"]}'
# The start of a worker_done body that shows the role still follows its common prompt (common-workers.md: "Start the body … with the word Done"):
# Done, or Hecho (the user's language may leak into a worker's report), as a whole word, any case, after leading blanks. A jq regex for test($re; "i").
# shellcheck disable=SC2034
REPORT_MARK_RE='^\s*(done|hecho)(\W|$)'
# 5 was the default of maxSelfMutants before 3: a user still on it moves to the new default.
# ["programmer"] was the default of researcher's modes before academic-research joined it: a user still on it moves to the new default.
# ["programmer"] was the default of dev's and tester's modes before they joined academic-research: a user still on it moves to the new default.
# auditor was the team's reviewer before this version split it into plan-reviewer and code-reviewer (and pr-reviewer's verifier): its entry is dropped, never carried over to the new roles (install.sh tells the user).
# claude-opus-5-5 was the default of the Writer's model before claude-sonnet-5-5: a user still on it moves to the new default.
# ["{kit}/plugin"] was the default of the planner's pluginDirs before superpowers: a user still on it moves to the new default.
# ["programmer"] was the default of the local coordinator's modes and "all" the planner's, before the local coordinator became every mode's front role: a user still on them moves to the new defaults.
# {"type":"sse","url":"https://mcp.atlassian.com/v1/sse"} was the default of the atlassian MCP server before Atlassian's /v2/mcp endpoint: a user still on exactly it moves to the new default.
# "first-use" was every kit role's own open value before defaults.open: a kit role the user still has on it moves to the kit's open value for it (none: it follows defaults.open), so that a defaults.open of the user's reaches it. Only a config with no defaults.open (one from before it) is moved: once the config has one, a kit role's "first-use" is the user's own.
# A user's own defaults.open other than the kit's is a team-wide choice: a kit role with no open of its own does not take the kit's new per-task or per-batch value.
# ["programmer", "academic-research"] was the default of researcher's, dev's and tester's modes before quick joined them: a user still on it moves to the new default.
upgrade_config() {  # $1 = config.default.json, $2 = the user's config.json, [$3 = the kit folder, unused] → stdout
  jq -s --argjson l "$LEGACY_ROLES" --argjson old_pw "$OLD_PLAYWRIGHT_MCP" "$LEGACY_JQ"' .[0] as $d | (.[1] | if (.roles? | type) == "object" then . else .roles = {} end | legacy($l)) as $u | ($d * $u) as $m
    | $m | .roles = ((($u.roles | keys_unsorted) + (($d.roles | keys_unsorted) - ($u.roles | keys_unsorted)))
                     | map({key: ., value: $m.roles[.]}) | from_entries)
    | del(.roles.auditor)
    | .roles |= with_entries(.key as $k
        | if (($u.defaults.open? // null) == null) and ($d.roles | has($k)) and ((.value | type) == "object") and ((($u.roles[$k]? | objects | .open?) // null) == "first-use")
          then (if ($d.roles[$k] | has("open")) then .value.open = $d.roles[$k].open else .value |= del(.open) end)
          elif (($u.defaults.open? // null) != null) and ($u.defaults.open != $d.defaults.open) and ($d.roles | has($k)) and (($d.roles[$k].open? // "") | IN("per-task", "per-batch")) and ((.value | type) == "object") and ((($u.roles[$k]? | type) != "object") or (($u.roles[$k] | has("open")) | not))
          then .value |= del(.open)
          else . end)
    | .roles.tester.params.maxSelfMutants |= (if . == 5 then $d.roles.tester.params.maxSelfMutants else . end)
    | .roles.researcher.modes |= (if . == ["programmer"] then $d.roles.researcher.modes else . end)
    | .roles.dev.modes |= (if . == ["programmer"] then $d.roles.dev.modes else . end)
    | .roles.tester.modes |= (if . == ["programmer"] then $d.roles.tester.modes else . end)
    | .roles.researcher.modes |= (if . == ["programmer", "academic-research"] then $d.roles.researcher.modes else . end)
    | .roles.dev.modes |= (if . == ["programmer", "academic-research"] then $d.roles.dev.modes else . end)
    | .roles.tester.modes |= (if . == ["programmer", "academic-research"] then $d.roles.tester.modes else . end)
    | .roles.writer.model |= (if . == "claude-opus-5-5" then $d.roles.writer.model else . end)
    | .roles.planner.pluginDirs |= (if . == ["{kit}/plugin"] then $d.roles.planner.pluginDirs else . end)
    | .roles["local-coordinator"].modes |= (if . == ["programmer"] then $d.roles["local-coordinator"].modes else . end)
    | if (($u.roles["local-coordinator"].modelByMode.quick? // null) == null)
         and ((($u.roles["local-coordinator"].agent? // $u.defaults.agent? // "claude") != "claude")
              or ((($u.roles["local-coordinator"].model? // null) | . != null and . != $d.roles["local-coordinator"].model)))
      then .roles["local-coordinator"].modelByMode |= (if type == "object" then del(.quick) else . end)
           | if .roles["local-coordinator"].modelByMode == {} then del(.roles["local-coordinator"].modelByMode) else . end
      else . end
    | .roles.planner.modes |= (if . == "all" then $d.roles.planner.modes else . end)
    | if ($u.mcpServers.atlassian? // null) == {"type":"sse","url":"https://mcp.atlassian.com/v1/sse"} then .mcpServers.atlassian = $d.mcpServers.atlassian else . end
    | if ($u.mcpServers.playwright? // null) == $old_pw then .mcpServers.playwright = $d.mcpServers.playwright else . end' "$1" "$2"
}
# launch.sh exceptions (options of the project's setup script, or of 'roles') as JSON:
#   {"only": [...], "enable": [...], "disable": [...], "set": [{"path": [...], "value": ...}], "mode": "<mode id>"}
# overrides_from_args [--only a,b] [--enable a,b] [--disable a,b] [--set dotted.path=value] [--mode id] ...  → stdout; 1 on error
# Lists add up if an option repeats. In --set the value is read as JSON if it is JSON (true, 10, ["x"]) and as text otherwise.
overrides_from_args() {
  local o='{"only":[],"enable":[],"disable":[],"set":[]}' opt val k explicit=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --only=*|--enable=*|--disable=*|--set=*|--mode=*) opt="${1%%=*}"; val="${1#*=}";;
      --only|--enable|--disable|--set|--mode) opt="$1"; [ $# -ge 2 ] || { echo "ERROR: $1 needs a value" >&2; return 1; }; val="$2"; shift;;
      *) echo "ERROR: unknown option: $1" >&2; return 1;;
    esac
    shift
    k="${opt#--}"
    if [ "$k" = mode ]; then
      o="$(jq -c --arg v "$val" '.mode = $v' <<<"$o")"; explicit=1
    elif [ "$k" = set ] && case "$val" in settings.mode=*) true;; *) false;; esac; then
      # --set settings.mode=x is the same request as --mode x (and --mode wins if both are given)
      [ "$explicit" = 1 ] || o="$(jq -c --arg v "${val#*=}" '.mode = $v' <<<"$o")"
    elif [ "$k" = set ]; then
      case "$val" in *=*) ;; *) echo "ERROR: --set expects path=value (e.g. roles.dev.model=claude-opus-5-5): $val" >&2; return 1;; esac
      case "${val%%=*}" in settings|roles) echo "ERROR: --set replaces one value, not a whole object: use --set settings.<key>=value (or roles.<role>.<key>=value)" >&2; return 1;; esac
      o="$(jq -c --arg p "${val%%=*}" --arg v "${val#*=}" --argjson l "$LEGACY_ROLES" '.set += [{path: ($p | split(".") | if .[0] == "roles" and $l[.[1]] then .[1] = $l[.[1]] else . end), value: ($v | try fromjson catch $v)}]' <<<"$o")"
    else
      o="$(jq -c --arg k "$k" --arg v "$val" --argjson l "$LEGACY_ROLES" '.[$k] += ($v | split(",") | map(gsub("^ +| +$"; "")) | map(select(. != "")) | map($l[.] // .))' <<<"$o")"
    fi
  done
  printf '%s\n' "$o"
}
# Combines a worktree's saved exceptions with the ones of the current run: the new ones add to the saved ones.  merge_overrides <saved> <new> [<previous effective mode>] → stdout
# only: the new list if it has any, else the saved one. enable/disable: both lists, a role named in the new one leaves the other saved one.
# set: the saved entries whose path is not set again, then the new ones. mode: the new one if present, else the saved one.
# Role selections belong to a mode: if the new mode differs from the previous effective mode (the third argument; without it, the saved mode, none saved = programmer), the saved only/enable/disable are dropped.
merge_overrides() {
  jq -c --slurpfile n "$2" --arg p "${3:-}" '$n[0] as $n
    | (if ($n.mode // null) != null and $n.mode != (if $p != "" then $p else (.mode // "programmer") end) then .only = [] | .enable = [] | .disable = [] else . end)
    | def uniq: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
      {only: (if ($n.only // [] | length) > 0 then $n.only else (.only // []) end),
       enable: ((((.enable // []) - ($n.disable // [])) + ($n.enable // [])) | uniq),
       disable: ((((.disable // []) - ($n.enable // [])) + ($n.disable // [])) | uniq),
       set: (((.set // []) | map(select(.path as $p | ($n.set // []) | map(.path) | index([$p]) | not))) + ($n.set // []))}
      + (if ($n.mode // null) != null then {mode: $n.mode} elif (.mode // null) != null then {mode: .mode} else {} end)' "$1"
}
# The role auditor was removed (split into plan-reviewer and code-reviewer; pr-reviewer's verifier): a configuration or exception that still
# names it is an error, never mapped to the new roles.  removed_role_error <config> [<overrides>] → one "ERROR: ..." line, or nothing
removed_role_error() {
  local named=0
  jq -e '(.roles? // {}) | type == "object" and has("auditor")' "$1" >/dev/null 2>&1 && named=1
  if [ -n "${2:-}" ] && jq -e '([(.only // [])[], (.enable // [])[], (.disable // [])[]] | index("auditor") != null)
      or ((.set // []) | any(.path[0] == "roles" and .path[1] == "auditor"))' "$2" >/dev/null 2>&1; then named=1; fi
  [ "$named" = 0 ] || echo "ERROR: the role auditor no longer exists in this version of orca-roles: the Plan-Reviewer (plan-reviewer) and the Code-Reviewer (code-reviewer) do its work in programmer mode, and the Verifier (verifier) in pr-reviewer mode. Remove auditor from where this worktree's team names it (~/.orca-roles/config.json, the project's .orca-roles.json, the setup script's options, or this worktree's saved exceptions: roles --reset), name the new roles instead if you need to, and run roles again. Nothing was changed."
}
# Checks that the exceptions only name existing roles and do not disable the planner or the local coordinator.  check_overrides <config> <overrides>
check_overrides() {
  local rr; rr="$(removed_role_error "$1" "$2")"
  if [ -n "$rr" ]; then echo "$rr"; return 0; fi
  jq -r --slurpfile o "$2" '(.roles | keys) as $ks | $o[0] as $o
    | ([$o.only[], $o.enable[], $o.disable[]] | unique | map(select(. as $r | $ks | index($r) | not))
       | if length > 0 then "ERROR: unknown roles: \(join(", ")). Available: \($ks | join(", "))" else empty end),
      (if ($o.disable | index("planner")) then "ERROR: the planner cannot be disabled" else empty end),
      (if ($o.disable | index("local-coordinator")) then "ERROR: the local coordinator cannot be disabled" else empty end)' "$1"
}
# Checks the configuration the exceptions produce: its mode, the "modes" and "prompt" of every role, and that the roles named by
# --only/--enable/--disable are part of the mode. One "ERROR: ..." line per problem, nothing if it is fine.  check_config <applied config> [<overrides>]
check_config() {
  local m out rr
  rr="$(removed_role_error "$1" "${2:-}")"
  if [ -n "$rr" ]; then echo "$rr"; return 0; fi
  out="$(jq -r --argjson ms "$MODES_JSON" --arg ml "$MODE_LIST" '.roles | to_entries[] | .key as $r | .value as $v
    | (if ($v | has("modes")) then
        ($v.modes | if . == "all" then empty
          elif type == "array" and length > 0 then
            (map(select(type != "string" or (. as $x | $ms | index($x) | not))) | if length > 0 then "ERROR: role \($r): modes has unknown mode ids (\(map(tostring) | join(", "))); modes: \($ml)\(if index("academic-writer") then " (academic-writer was renamed: use academic-research)" else "" end)" else empty end)
          else "ERROR: role \($r): modes must be \"all\" or a non-empty list of mode ids (modes: \($ml))" end)
      else empty end),
      (if ($v | has("phases")) then
        ($v.phases | if type == "array" and length > 0 and all(.[]; . == "experiment" or . == "writing") then empty
          else "ERROR: role \($r): phases must be a non-empty list of \"experiment\", \"writing\"" end)
      else empty end),
      (if ($v | has("modelByMode")) then
        ($v.modelByMode | if type == "object" and all(to_entries[]; (.key as $k | $ms | index($k)) != null and (.value | type) == "string") then empty
          else "ERROR: role \($r): modelByMode must map mode ids to model ids (modes: \($ml))" end)
      else empty end),
      (if ($v | has("prompt")) then
        ($v.prompt | if . == null or type == "string" then empty
          elif type == "object" then
            (to_entries | map(select((.key as $k | $ms | index($k) | not) or (.value | type) != "string")) | if length > 0 then "ERROR: role \($r): prompt must map mode ids to file paths (invalid: \(map(.key) | join(", ")); modes: \($ml))" else empty end)
          else "ERROR: role \($r): prompt must be a path or an object {\"<mode>\": path}" end)
      else empty end)' "$1")" || { echo "ERROR: invalid configuration: roles must be objects (check ~/.orca-roles/config.json and .orca-roles.json)"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r '.roles | to_entries[] | select(.value | has("disallowedTools")) | select(.value.disallowedTools | type != "array" or any(.[]; type != "string"))
    | "ERROR: role \(.key): disallowedTools must be a list of tool names"' "$1" 2>/dev/null)" || true
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r --arg ha "$HIDDEN_AGENTS" '(.roles | to_entries[] | select(.value | type == "object" and has("open")) | select(.value.open | IN("start", "first-use", "per-task", "per-batch", "hidden") | not)
      | "ERROR: role \(.key): open must be \"start\", \"first-use\", \"per-task\", \"per-batch\" or \"hidden\" (got \(.value.open | tojson))"),
    (.defaults? | objects | select(has("open")) | select(.open | IN("start", "first-use", "per-task", "per-batch", "hidden") | not)
      | "ERROR: defaults.open must be \"start\", \"first-use\", \"per-task\", \"per-batch\" or \"hidden\" (got \(.open | tojson))"),
    (($ha | split(" ") | map(select(. != ""))) as $hl | .defaults as $d | .roles | to_entries[] | select(.value | type == "object" and .open == "hidden")
      | if .key == "planner" or .key == "local-coordinator" then "ERROR: role \(.key): open \"hidden\" is not allowed: this role needs a tab"
        else (.value.agent // $d.agent // "claude") as $ag | select($hl | index($ag) | not)
          | "ERROR: role \(.key): open \"hidden\" needs agent \"\($hl | join(", "))\" (got \"\($ag)\")" end)' "$1" 2>/dev/null)" || true
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r '(.roles | to_entries[] | .key as $r | .value as $v
      | (if ($r | test("-[0-9]+$")) then "ERROR: role \($r): a role id must not end in a hyphen and digits (the kit names a role'"'"'s extra instances that way)" else empty end),
        (if ($v | type) == "object" then
          (if ($v | has("instanceOf")) then "ERROR: role \($r): instanceOf is reserved for the kit'"'"'s instances" else empty end),
          (if ($v | has("maxInstances")) and $v.maxInstances != null then
            ($v.maxInstances | if type != "number" or . != floor or . < 1 then "ERROR: role \($r): maxInstances must be a positive integer"
              elif . > 1 and ($r | IN("planner", "plan-reviewer", "code-reviewer", "local-coordinator")) then "ERROR: role \($r): maxInstances must be 1: this role never has instances"
              else empty end)
           else empty end)
         else empty end)),
    (.settings // {} | if has("scaling") and .scaling != null then
        (.scaling | if type != "object" then "ERROR: invalid configuration: settings.scaling must be an object"
          else
            ((keys - ["maxExtraInstances", "maxLoad", "minFreeMemoryMB"]) as $k | if ($k | length) > 0 then "ERROR: invalid configuration: settings.scaling has unknown keys (\($k | join(", "))); its keys are maxExtraInstances, maxLoad and minFreeMemoryMB" else empty end),
            (if has("maxExtraInstances") and .maxExtraInstances != null and ((.maxExtraInstances | type) != "number" or .maxExtraInstances != (.maxExtraInstances | floor) or .maxExtraInstances < 0) then "ERROR: invalid configuration: settings.scaling.maxExtraInstances must be a non-negative integer" else empty end),
            (if has("maxLoad") and .maxLoad != null and ((.maxLoad | type) != "number" or .maxLoad <= 0) then "ERROR: invalid configuration: settings.scaling.maxLoad must be a number above 0" else empty end),
            (if has("minFreeMemoryMB") and .minFreeMemoryMB != null and ((.minFreeMemoryMB | type) != "number" or .minFreeMemoryMB != (.minFreeMemoryMB | floor) or .minFreeMemoryMB < 0) then "ERROR: invalid configuration: settings.scaling.minFreeMemoryMB must be a non-negative integer" else empty end)
          end)
      else empty end)' "$1" 2>/dev/null)" \
    || { echo "ERROR: invalid configuration: roles.<role>.maxInstances and settings.scaling must be valid (see README)"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r '[(.defaults?, .roles[]?) | objects | select(has("modelError")) | .modelError | select(type != "string" or . == "")]
    | if length > 0 then "ERROR: invalid configuration: modelError must be a non-empty string" else empty end' "$1" 2>/dev/null)" \
    || { echo "ERROR: invalid configuration: modelError must be a non-empty string"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r '[(.defaults?, .roles[]?) | objects | select(has("models")) | .models
      | select((type != "object") or ((keys - ["list", "parse", "probe"]) | length > 0)
        or (has("list") and ((.list | type) != "string" or .list == "")) or (has("probe") and ((.probe | type) != "string" or .probe == ""))
        or (has("parse") and ((.parse | type) != "string" or (.parse != "lines" and (.parse | test("^(json|regex):.+") | not)))))]
    | if length > 0 then "ERROR: invalid configuration: models must be {list, parse, probe} (see README)" else empty end' "$1" 2>/dev/null)" \
    || { echo "ERROR: invalid configuration: models must be {list, parse, probe} (see README)"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r '.settings // {} | if has("prReviewer") then (.prReviewer | select((type != "object") or ([.marketplace, .plugin, .skill] | map(select(type != "string" or . == "")) | length > 0))
      | "ERROR: invalid configuration: settings.prReviewer must be {marketplace, plugin, skill}") else empty end' "$1" 2>/dev/null)" \
    || { echo "ERROR: invalid configuration: settings.prReviewer must be {marketplace, plugin, skill}"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r '.settings // {} | if has("superpowers") then (.superpowers | select(. != true and . != false) | "ERROR: invalid configuration: settings.superpowers must be true or false") else empty end' "$1" 2>/dev/null)" \
    || { echo "ERROR: invalid configuration: settings.superpowers must be true or false"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r '.settings // {} | if has("enableAskModeOnStart") then (.enableAskModeOnStart | select(. != true and . != false) | "ERROR: invalid configuration: settings.enableAskModeOnStart must be true or false") else empty end' "$1" 2>/dev/null)" \
    || { echo "ERROR: invalid configuration: settings.enableAskModeOnStart must be true or false"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r '.settings // {} | if has("artifacts") then (.artifacts
      | if type != "object" or ((keys - ["plans", "designs", "research", "deployment"]) | length) > 0 then "ERROR: invalid configuration: settings.artifacts must be an object with only plans, designs, research, deployment"
        else (to_entries[] | select(.value | type != "string" or . == "" or startswith("/") or startswith("~") or (split("/") | any(. == "..")) or (split("/")[0] | startswith("-")) or (split("/") | any(ascii_downcase == ".git")) or . == "." or . == "./" or (test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*/?\\z") | not))
          | "ERROR: invalid configuration: settings.artifacts.\(.key) must be a relative path inside the worktree") end) else empty end' "$1" 2>/dev/null)" \
    || { echo "ERROR: invalid configuration: settings.artifacts must be an object with only plans, designs, research, deployment"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r '.settings // {} | if has("phase") then (.phase | select(. != "experiment" and . != "writing") | "ERROR: invalid configuration: settings.phase must be \"experiment\" or \"writing\"") else empty end' "$1" 2>/dev/null)" \
    || { echo "ERROR: invalid configuration: settings.phase must be \"experiment\" or \"writing\""; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  out="$(jq -r 'def P: "ERROR: invalid configuration: ";
      def pint: type == "number" and . == floor and . >= 1;
      def nn: (type == "number" and . >= 0) or (type == "string" and test("^([0-9]+\\.?[0-9]*|\\.[0-9]+)\\z"));
      def got($k): has($k) and .[$k] != null;
      def objs($k; $path; f): if got($k) then (.[$k] | if type == "object" then f else P + "\($path) must be an object" end) else empty end;
      (.settings // {}) as $s | ($s | if type == "object" then . else {} end) as $s
      | ($s | objs("flow"; "settings.flow";
          (if got("roundCap") and (.roundCap | pint | not) then P + "settings.flow.roundCap must be a positive integer" else empty end),
          (if got("maxStepsPerWorker") and (.maxStepsPerWorker | pint | not) then P + "settings.flow.maxStepsPerWorker must be a positive integer" else empty end),
          (if got("workerReportBody") and (.workerReportBody != "full" and .workerReportBody != "short") then P + "settings.flow.workerReportBody must be \"full\" or \"short\"" else empty end),
          (if got("crossCheck") and (.crossCheck != true and .crossCheck != false) then P + "settings.flow.crossCheck must be true or false" else empty end),
          (if got("recordRounds") and (.recordRounds != true and .recordRounds != false) then P + "settings.flow.recordRounds must be true or false" else empty end),
          objs("escalation"; "settings.flow.escalation";
            (to_entries[] | select(.value != null) | .key as $r | .value as $v
              | if $r == "planner" then P + "settings.flow.escalation.planner is not allowed (the Planner'"'"'s model is set in roles.planner.model)"
                elif $r == "local-coordinator" then P + "settings.flow.escalation.local-coordinator is not allowed (the local coordinator is never relaunched)"
                elif ($v | type == "object" and ((.to | type == "string" and . != "" and (test("\\s") | not))) and ((got("after") | not) or (.after | pint))) then empty
                else P + "settings.flow.escalation.\($r) must be {\"to\": \"<model>\", \"after\": <positive integer>}" end)))),
        ($s | objs("oracle"; "settings.oracle";
          (if got("enabled") and (.enabled != true and .enabled != false) then P + "settings.oracle.enabled must be true or false" else empty end),
          (. as $o | ("maxLoad", "waitMax", "timeout", "retries") as $k | select($o | got($k) and (.[$k] | nn | not)) | P + "settings.oracle.\($k) must be a non-negative number"))),
        ($s | if got("sessionHook") and (.sessionHook != true and .sessionHook != false) then P + "settings.sessionHook must be true or false" else empty end),
        ($s | objs("telemetry"; "settings.telemetry";
          (if got("roleAttribute") and (.roleAttribute != true and .roleAttribute != false) then P + "settings.telemetry.roleAttribute must be true or false" else empty end))),
        ($s | objs("metrics"; "settings.metrics";
          (if got("enabled") and (.enabled != true and .enabled != false) then P + "settings.metrics.enabled must be true or false" else empty end),
          (if got("allowRemote") and (.allowRemote != true and .allowRemote != false) then P + "settings.metrics.allowRemote must be true or false" else empty end),
          (. as $m | ("otlpEndpoint", "prometheusUrl") as $k | select($m | got($k) and (.[$k] | type == "string" and test("^https?://.") | not)) | P + "settings.metrics.\($k) must be a URL starting with http:// or https://"),
          (if got("intervalSeconds") and (.intervalSeconds | type == "number" and . == floor and . >= 15 and . <= 3600 | not) then P + "settings.metrics.intervalSeconds must be an integer from 15 to 3600" else empty end),
          (if got("prometheusContainer") and (.prometheusContainer | type == "string" and length > 0 | not) then P + "settings.metrics.prometheusContainer must be a non-empty string" else empty end),
          (if got("retentionDays") and (.retentionDays | type == "number" and . == floor and . >= 1 and . <= 3650 | not) then P + "settings.metrics.retentionDays must be an integer from 1 to 3650" else empty end))),
        ($s | if got("trust") and (.trust != "worktree" and .trust != "never") then P + "settings.trust must be \"worktree\" or \"never\"" else empty end),
        ((.roles // {}) | to_entries[] | .key as $r | select(.value | type == "object" and got("opencode")) | .value.opencode
          | if type != "object" then "ERROR: invalid configuration: role \($r): opencode must be an object"
            else (if got("steps") and (.steps | pint | not) then "ERROR: invalid configuration: role \($r): opencode.steps must be a positive integer" else empty end),
              (if got("permissions") and (.permissions | type != "array" or any(.[]; type != "object" or (.action | type) != "string" or (.resource | type) != "string" or (.effect | IN("allow", "ask", "deny") | not)))
                then "ERROR: invalid configuration: role \($r): opencode.permissions must be a list of {\"action\", \"resource\", \"effect\": \"allow\"|\"ask\"|\"deny\"}" else empty end) end)' "$1" 2>/dev/null)" \
    || { echo "ERROR: invalid configuration: settings.flow, settings.oracle, settings.telemetry, settings.metrics, settings.trust and roles.<role>.opencode must be valid (see README)"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
  m="$(mode_of "$1" 2>&1)" || { echo "ERROR: $m"; return 0; }
  [ -n "${2:-}" ] || return 0
  out="$(jq -r --slurpfile o "$2" --arg m "$m" --arg f "$(front_role "$m")" '$o[0] as $o | .roles as $R | [$o.only[], $o.enable[], $o.disable[]] | unique[]
    | select(. != $f and $R[.] != null)
    | . as $r | ($R[$r].modes // ["programmer"]) as $rm
    | select($rm | if . == "all" then false elif type == "array" then (index($m) == null) else false end)
    | "ERROR: role \($r) is not part of mode \($m) (its modes: \($rm | if type == "array" then join(", ") else tostring end))"' "$1")" || { echo "ERROR: could not check the exceptions against the mode"; return 0; }
  [ -z "$out" ] || printf '%s\n' "$out"
}
# Applies the exceptions to a configuration: --only (the planner and the local coordinator always stay), then --enable, --disable, --set and --mode.  apply_overrides <config> <overrides>
apply_overrides() {
  jq --slurpfile o "$2" '$o[0] as $o
    | if ($o.only | length) > 0 then .roles |= with_entries(.value.enabled = (.key == "planner" or .key == "local-coordinator" or (.key as $k | $o.only | index($k)) != null)) else . end
    | reduce $o.enable[] as $r (.; .roles[$r].enabled = true)
    | reduce $o.disable[] as $r (.; .roles[$r].enabled = false)
    | reduce $o.set[] as $s (.; setpath($s.path; $s.value))
    | if ($o.mode // null) != null then .settings.mode = $o.mode else . end' "$1"
}
# The role's environment variables (defaults.env + roles.<role>.env) as KEY=VALUE lines.  role_env <config> <role>
role_env() { jq -r --arg r "$2" '((.defaults.env // {}) * (.roles[$r].env // {})) | to_entries[] | "\(.key)=\(.value)"' "$1"; }
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
# The worktree's Jira ticket for the Planner, as two lines: key and url (no key with settings.jiraHandoff off). The key comes
# from Orca's linked work item or, without one, from the branch (see jira_key).  worktree_jira <worktree> <config>
worktree_jira() {
  local j id url key
  j="$(orca worktree show --worktree "$1" --json 2>/dev/null)"
  id=$(printf '%s' "$j" | jq -r '[.. | objects | select(.provider? == "jira") | .jiraIdentifier // empty] | first // empty' 2>/dev/null)
  url=$(printf '%s' "$j" | jq -r '[.. | objects | select(.provider? == "jira") | .url // empty] | first // ([.. | strings | select(test("atlassian\\.net/browse/"))] | first) // empty' 2>/dev/null)
  key="$(jira_key "$(git branch --show-current 2>/dev/null)" "$id" "$url")"
  [ "$(setting "$2" jiraHandoff true)" = true ] || key=""
  printf '%s\n%s\n' "$key" "$url"
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
# settings.flow: optional per-worktree tuning of the flow that the prompts describe in prose.  Unset = the prompts' own values and
# the messages are byte-identical to a config without the key; an invalid value is ignored with a warning on stderr.
#   roundCap: positive integer (rejected Tester rounds of a step before the local coordinator sends the Planner a decide task; the prompt says 3). programmer mode only
#   maxStepsPerWorker: positive integer, the default `steps` of an OpenCode role (roles.<r>.opencode.steps wins). OpenCode roles only
#   workerReportBody: "full" (default) or "short" (worker_done body of a few lines, the detail in a file in scratchDir)
#   crossCheck: true turns on the cross-check (Cross-Dev writes an independent candidate the Tester checks against). programmer mode,
#   with the cross-dev role active, only
# flow_round_cap <config> → stdout: the number, or nothing.   flow_report_body <config> → stdout: "short", or nothing.   flow_max_steps <config> → stdout: the number, or nothing.
flow_round_cap() {
  local r; r="$(jq -r '(.settings.flow? | objects | .roundCap?) // empty | if type == "number" and . == floor and . > 0 then "ok \(.)" else "bad \(tojson)" end' "$1" 2>/dev/null)"
  case "$r" in
    "ok "*) printf '%s' "${r#ok }";;
    "bad "*) echo "orca-roles: settings.flow.roundCap must be a positive integer (got ${r#bad }); ignoring it" >&2;;
  esac
  return 0
}
flow_report_body() {
  local r; r="$(jq -r '(.settings.flow? | objects | .workerReportBody?) // empty | if . == "full" then "" elif . == "short" then "short" else "bad \(tojson)" end' "$1" 2>/dev/null)"
  case "$r" in
    short) printf 'short';;
    "bad "*) echo "orca-roles: settings.flow.workerReportBody must be \"full\" or \"short\" (got ${r#bad }); ignoring it" >&2;;
  esac
  return 0
}
flow_max_steps() {
  local r; r="$(jq -r '(.settings.flow? | objects | .maxStepsPerWorker?) // empty | if type == "number" and . == floor and . > 0 then "ok \(.)" else "bad \(tojson)" end' "$1" 2>/dev/null)"
  case "$r" in
    "ok "*) printf '%s' "${r#ok }";;
    "bad "*) echo "orca-roles: settings.flow.maxStepsPerWorker must be a positive integer (got ${r#bad }); ignoring it" >&2;;
  esac
  return 0
}
# flow_cross_check <config> <active roles> → status 0 when the cross-check applies; warnings on stderr when it is set but cannot apply
flow_cross_check() {
  local v; v="$(jq -r '(.settings.flow? | objects | .crossCheck?) // empty | if type == "boolean" then tostring else "bad \(tojson)" end' "$1" 2>/dev/null)"
  case "$v" in
    true) ;;
    "bad "*) echo "orca-roles: settings.flow.crossCheck must be true or false (got ${v#bad }); ignoring it" >&2; return 1;;
    *) return 1;;
  esac
  [ "$(mode_of --saved "$1")" = programmer ] || return 1
  case " $2 " in *" cross-dev "*) ;; *) echo "orca-roles: settings.flow.crossCheck needs the cross-dev role enabled in this worktree; ignoring it" >&2; return 1;; esac
  if [ "$(rstr "$1" cross-dev agent)" = "$(rstr "$1" dev agent)" ] && [ "$(role_model "$1" cross-dev)" = "$(role_model "$1" dev)" ]; then
    echo "orca-roles: cross-dev runs the same agent and model as dev, so their mistakes will tend to match; a different model family makes the cross-check stronger" >&2
  fi
  return 0
}
# settings.flow.escalation.<role> = {"to": "<model>", "after": N}: round.sh relaunches that role on "to" once a step has N (default 1)
# rejected rounds and back on its own model when the step is accepted. Neither the Planner nor the local coordinator can be escalated.
# flow_escalation <config> <role> → stdout: "<model> <after>", or nothing (unset, or invalid with a warning on stderr).
flow_escalation() {
  local r; r="$(jq -r --arg r "$2" '(.settings.flow? | objects | .escalation? | objects | .[$r]?) // empty
    | if type == "object" and (.to | type) == "string" and (.to | test("^[^[:space:]]+$")) and $r != "planner" and $r != "local-coordinator"
         and ((.after // 1) | type == "number" and . == floor and . > 0)
      then "ok \(.to) \(.after // 1)" else "bad \(tojson)" end' "$1" 2>/dev/null)"
  case "$r" in
    "ok "*) printf '%s' "${r#ok }";;
    "bad "*) echo "orca-roles: settings.flow.escalation.$2 must be {\"to\": \"<model>\", \"after\": <positive integer>} and not the Planner or the local coordinator (got ${r#bad }); ignoring it" >&2;;
  esac
  return 0
}
# settings.flow.recordRounds is true: the Planner records every worker round with round.sh (see README, Round log).  flow_record_rounds <config>
flow_record_rounds() { [ "$(jq -r '(.settings.flow? | objects | .recordRounds?) == true' "$1" 2>/dev/null)" = true ]; }
# settings.oracle.enabled is true: the Planner runs the executable oracle (bin/oracle.sh) on Dev's work.  oracle_enabled <config>
oracle_enabled() { [ "$(jq -r '(.settings.oracle? | objects | .enabled?) == true' "$1" 2>/dev/null)" = true ]; }
# settings.telemetry.roleAttribute: agent.sh tags the agent's OpenTelemetry data with orca_roles.role=<role>
telemetry_role_attribute() { [ "$(jq -r '(.settings.telemetry? | objects | .roleAttribute?) == true' "$1" 2>/dev/null)" = true ]; }
# settings.metrics.enabled is not false: the kit records its usage metrics (events and worktrees below; the transcripts are read by usage-metrics.sh).  metrics_enabled <config>
metrics_enabled() { [ "$(jq -r '(.settings.metrics? | objects | .enabled?) == false' "$1" 2>/dev/null)" != true ]; }
# Where the kit keeps what the metrics pass needs: $KIT/metrics (created on the first write).
metrics_dir() { printf '%s\n' "$KIT/metrics"; }
# One JSON line appended to <metrics dir>/<file>; a failed write is ignored.  metrics_append <file> <jq args...> <program>
metrics_append() {
  local f d; f="$1"; shift; d="$(metrics_dir)"
  { mkdir -p "$d" && jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" >> "$d/$f"; } 2>/dev/null || true
  return 0
}
# A kit event: <worktree (physical path)> <event> <role> [<task>]
metrics_event() {
  if [ $# -ge 4 ]; then metrics_append events.jsonl --arg w "$1" --arg e "$2" --arg r "$3" --arg t "$4" '{ts: $ts, worktree: $w, event: $e, role: $r, task: $t}'
  else metrics_append events.jsonl --arg w "$1" --arg e "$2" --arg r "$3" '{ts: $ts, worktree: $w, event: $e, role: $r}'; fi
}
# The task of a worktree: task= in defaults.env.OTEL_RESOURCE_ATTRIBUTES of the config, else the worktree folder's name.  metrics_task <config> <worktree folder>
metrics_task() {
  local t
  t="$(jq -r '(.defaults.env? | objects | .OTEL_RESOURCE_ATTRIBUTES?) // "" | if type == "string" then split(",") | map(gsub("^\\s+|\\s+$"; "") | select(startswith("task="))) | first // "" | .[5:] else "" end' "$1" 2>/dev/null)" || t=""
  [ -n "$t" ] || t="$(basename "$2")"
  printf '%s\n' "$t"
}
# One worktrees.jsonl line: the worktree's path as git prints it, its physical path, its project and its task.  metrics_worktree <worktree top> <project> <task>
metrics_worktree() {
  metrics_append worktrees.jsonl --arg p "$1" --arg y "$(cd "$1" 2>/dev/null && pwd -P || printf '%s' "$1")" --arg j "$2" --arg t "$3" '{ts: $ts, path: $p, physical: $y, project: $j, task: $t}'
}
# The marker a coordinator leaves before it creates a worktree (prompts/coordinator.md), read from inside that worktree:
# <git common dir>/orca-roles.coordinated/<worktree folder name>. Only the front role's first start reads it, and kickoff.sh removes it then.
coordinated_marker() {
  local common top
  common="$(git_here common-dir)" && top="$(git_here toplevel)" || return 1
  printf '%s/orca-roles.coordinated/%s' "$(cd "$common" && pwd)" "${top##*/}"
}
# The Run of the coordinator that opened this worktree: the id it wrote in its marker, or the copy kickoff.sh keeps beside the state
# (<git dir>/orca-roles.coordinator) so it outlives the marker, the front role's restarts and its cleared conversations. Fails if none.
coordinator_run() {
  local f r
  for f in "$(coordinated_marker)" "$(dirname "$1")/orca-roles.coordinator"; do
    [ -f "$f" ] || continue
    r="$(head -n 1 "$f")"
    case "$r" in run_*[!A-Za-z0-9_]*) ;; run_?*) printf '%s' "$r"; return 0;; esac
  done
  return 1
}

# The front role's startup message: the local coordinator's in every mode (the Planner, where the mode has one, is a worker
# and is one of its handles).  planner_msg <config> "<enabled roles>" <state> <jira_key> <jira_url> <resume 0|1>
planner_msg() {
  local cfg="$1" roles="$2" state="$3" key="$4" url="$5" resume="$6" oldmode="${7:-}" id v t handles="" active="" extra params msg lang art cap oc esc e cm cr xc front lfirst ltask lhid lbatch linst team n
  front="$(front_role "$(mode_of --saved "$cfg")")"
  # shellcheck source=/dev/null
  . "$state"
  for id in $roles; do
    [ "$id" = "$front" ] && continue
    v="$(var_of "$id")"; t="$(title_of "$cfg" "$id")"
    handles="$handles $t=${!v},"; active="$active $t"
  done
  lfirst=""; ltask=""; lhid=""; lbatch=""; linst=""; team="$roles"
  for id in $(launchable_roles "$cfg" 2>/dev/null); do
    [ "$id" = "$front" ] && continue
    [ -z "$(instance_base "$cfg" "$id")" ] || continue
    case "$(open_of "$cfg" "$id")" in
      first-use) case " $roles " in *" $id "*) ;; *) lfirst="$lfirst, $(title_of "$cfg" "$id") ($id)"; team="$team $id";; esac;;
      per-task) ltask="$ltask, $(title_of "$cfg" "$id") ($id)"; case " $roles " in *" $id "*) ;; *) team="$team $id";; esac;;
      per-batch) lbatch="$lbatch, $(title_of "$cfg" "$id") ($id)"; case " $roles " in *" $id "*) ;; *) team="$team $id";; esac;;
      hidden) case " $roles " in *" $id "*) ;; *) lhid="$lhid, $(title_of "$cfg" "$id") ($id)"; team="$team $id";; esac;;
    esac
    n="$(max_instances "$cfg" "$id")"
    [ "$n" -gt 1 ] && linst="$linst, $(title_of "$cfg" "$id") ($id, up to $n)"
  done
  extra="$(jq -r --arg f "$front" --argjson act "$(printf '%s\n' $team | grep . | jq -R . | jq -s .)" \
    '[.roles | to_entries[] | select(.key != $f and (.value.instanceOf | not) and (.key as $k | $act | index($k)) and .value.description) | "\(.value.title // .key): \(.value.description)"] | join("; ")' "$cfg")"
  params="$(jq -r --arg f "$front" '((.defaults.params // {}) * (.roles[$f].params // {})) | to_entries | map("\(.key)=\(.value)") | join(", ")' "$cfg")"
  msg="Read $(prompt_of "$cfg" "$front") and adopt that role from now on. Mode: $(mode_of --saved "$cfg")."
  [ "$(mode_of --saved "$cfg")" = academic-research ] && msg="$msg Phase: $(phase_of "$cfg")."
  msg="$msg Active roles in this workspace:${active:- none}. Handles:${handles%,}."
  [ -n "$lfirst" ] && msg="$msg Roles opened on first use, not open yet (see \"The team\" in your prompt): ${lfirst#, }."
  [ -n "$ltask" ] && msg="$msg Roles opened per task (see \"The team\" in your prompt): ${ltask#, }."
  [ -n "$lbatch" ] && msg="$msg Roles opened per batch (see \"The team\" in your prompt): ${lbatch#, }."
  [ -n "$linst" ] && msg="$msg Roles that can run several instances at once (see \"The team\" in your prompt): ${linst#, }."
  [ -n "$lhid" ] && msg="$msg Hidden roles, with no tab, run with hidden-role.sh (see \"The team\" in your prompt): ${lhid#, }."
  lang="$(setting "$cfg" language auto)"   # settings.language: "auto" = the language the user writes in
  [ "$lang" != auto ] && [ -n "$lang" ] && msg="$msg Always reply to the user in $lang, whatever language they write in."
  [ -n "$params" ] && msg="$msg Configuration parameters: $params."
  art="$(jq -r '(.settings.artifacts | if type == "object" then . else {} end) | [("plans", "designs", "research", "deployment") as $k | select(has($k)) | "\($k)=\(.[$k])"] | join(", ")' "$cfg" 2>/dev/null)"
  [ -z "$art" ] || msg="$msg Artifact locations set for this worktree (they win over the project's conventions): $art."
  [ -n "$extra" ] && msg="$msg Additional roles (fit them into the flow according to their description): $extra."
  if [ "$(setting "$cfg" cleanWorkersAfterStep true)" = true ]; then msg="$msg When closing each step, clean the workers' context without asking the user (see your section \"Cleaning the workers' context\")."
  else msg="$msg Clean the workers' context only if the user asks you to."; fi
  cap=""; [ "$(mode_of --saved "$cfg")" = programmer ] && cap="$(flow_round_cap "$cfg")"   # settings.flow (see flow_round_cap); only programmer's flow has rounds
  [ -n "$cap" ] && msg="$msg Flow override: send the Planner a \`decide\` task when a step piles up $cap rejected Tester rounds (this replaces the 3 in your prompt)."
  [ "$(flow_report_body "$cfg")" = short ] && msg="$msg Flow override: the workers' worker_done reports are short (a few lines); the full detail is in the file whose absolute path the body names, which you read when you need it."
  xc=""; flow_cross_check "$cfg" "$team" && xc=1
  [ -n "$xc" ] && msg="$msg Flow override: the cross-check is on: follow your section \"Cross-check\" with $(title_of "$cfg" cross-dev)."
  esc=""; if [ "$(mode_of --saved "$cfg")" = programmer ]; then   # settings.flow.escalation (see README, Escalation): the active roles with a valid one
    for id in $team; do e="$(flow_escalation "$cfg" "$id" 2>/dev/null)"; [ -n "$e" ] && esc="$esc, $(title_of "$cfg" "$id") to ${e% *} after ${e#* } rejected round(s) of a step"; done
  fi
  if [ "$(mode_of --saved "$cfg")" = programmer ] && { flow_record_rounds "$cfg" || [ -n "$esc" ]; }; then   # settings.flow.recordRounds (see README, Round log); off = byte-identical message
    if [ -z "$esc" ]; then
      msg="$msg Round log: after each Dev round, once you have its verdict (the Tester's ACCEPTED or REJECTED, or the oracle's red) and before the next dispatch, run \`$(kit_env)$KIT/bin/round.sh dev --step <step> --round <n> --outcome accepted|rejected|oracle-red --task <task id>\` from the worktree (oracle-red when the oracle is red, whatever the Tester says). It only appends a line to a local file; never call it with a dispatch to Dev in flight."
    else
      msg="$msg Round log and escalation: after each round of a worker that writes code (Dev, or the role you gave the step to), once you have its verdict (the Tester's ACCEPTED or REJECTED, or the oracle's red) and before the next dispatch, run \`$(kit_env)$KIT/bin/round.sh <role> --step <step> --round <n> --outcome accepted|rejected|oracle-red --task <task id>\` from the worktree (oracle-red when the oracle is red, whatever the Tester says). Never call it with a dispatch to that role in flight. It escalates${esc#,}: it relaunches the role on that model, and on the step's accepted round it brings it back to its own model. This is configured, so it does not need the user's confirmation; when it relaunches a role, tell the user in one line (not as a question) and use the new handle it prints for the next dispatch. The rejected rounds keep counting toward the step's limit across models."
    fi
    [ -n "$xc" ] && msg="$msg With the cross-check on, add \`--cross agree|disagree|none\` to each of those round.sh calls: the Tester's Cross-check result for that round, none when Cross-Dev left no candidate."
  fi
  if [ "$(mode_of --saved "$cfg")" = programmer ] && oracle_enabled "$cfg"; then   # settings.oracle (see README, Optional oracle); off = byte-identical message
    msg="$msg Oracle: every Dev task spec gets a section \`## Acceptance command\` with a fenced block of commands from the allowlist (pytest, ruff, mypy, npm/pnpm/yarn test|lint|build|typecheck, vitest, jest, tsc, eslint, playwright test, make, go test|vet|build, cargo test|check|clippy|build, bash <file>.sh; joined only with &&, no pipes or redirections). Write each Dev spec to a file in your scratchDir first, compute \`shasum -a 256 <file>\`, create the Orca task with a line \`spec-sha256: <hex>\` in its --spec, then rename the file to spec-<task_id>.md and never edit it afterwards (a changed spec is a new task); after each Dev worker_done, before briefing the Tester, run \`$(kit_env)$KIT/bin/oracle.sh --task <task_id> --spec-file <that file> --base <the step's base ref: the previous step's last checkpoint ref, or HEAD for the first step of the set>\`: pass or pass_flaky means go on to the Tester (a non-empty runner_config_changed in its integrity goes into the Tester's brief as state); fail, a cheat, command_not_allowed, env_not_runnable or no_acceptance_command means back to Dev with the oracle's output (a rejected round). If the oracle answers spec_tampered, stop the step and tell the user (a worker changed the spec file). If it reports spec_check unverified, run it once more; still unverified: stop the step and tell the user in one line with its reason. The Tester's VERDICT stays, but the oracle decides whether the step's code is accepted."
  fi
  # OpenCode workers run with a private OpenCode server in their tab (agent.sh, --standalone): closing the tab ends their turn. What Orca
  # itself supervises for them is not verified, and dispatch.sh skips its start check for them.
  oc=""; for id in $team; do [ "$(rstr "$cfg" "$id" agent)" = opencode ] && oc="${oc:+$oc, }$(title_of "$cfg" "$id")"; done
  [ -n "$oc" ] && msg="$msg OpenCode workers ($oc): each runs with its own OpenCode server inside its tab, so closing the tab ends its turn; to stop one, run \`$(kit_env)$KIT/bin/close-role.sh <id>\`. Whether Orca's worker-show, worker-stop and worker-abandon act on them is not verified, and dispatch.sh does not check that their tasks started; their worker_done reaches you as usual."
  [ -n "$key" ] && msg="$msg This worktree is linked to the Jira ticket $key${url:+ ($url)}: read it with Jira and use it as the starting point for planning."
  # a coordinator reads its Run's mailbox, never this tab: without this a task it typed here leaves the front role asking in the tab
  if cr="$(coordinator_run "$state")"; then
    msg="$msg This worktree works under a coordinator whose Run is $cr, and it does not read this tab. Outside a dispatch from it (for example when it typed your task here), everything your prompt has you ask, propose or report to the user goes to it as an Orca message: bind your own Run first (create it with the task's objective if you have none yet), then \`orca orchestration send --to run:$cr --type question --subject \"<branch>: <topic>\" --body \"<text>\" --json\`, with \`--type status\` for a report or the end of the task and the absolute path of the file that holds it. Its answers reach your Run's mailbox like your workers' messages. Never ask it in this tab or in a question dialog. Inside a dispatch from it, use the preamble's commands. If the user writes in this tab, the user takes precedence."
  fi
  if [ "$resume" = 1 ]; then
    msg="$msg WARNING: this workspace is being RESUMED after a restart. The team's previous terminals died and the handles above are new. Before talking to the user, follow the section \"Resuming a workspace after a restart\" of your prompt: recover the Run, the tasks, the latest communications and the state of the code, and give them a summary. Start there."
  elif [ "$resume" = 3 ]; then
    msg="$msg WARNING: your conversation was cleared (for example with /clear) while the team kept running: the handles above are current and the dispatches in flight are still valid. Before talking to the user, follow the section \"After your conversation was cleared\" of your prompt. Start there."
  elif [ "$resume" = 4 ]; then
    msg="$msg WARNING: the mode was switched from $oldmode to $(mode_of --saved "$cfg") and your conversation was cleared on purpose. If the user asked you to save a summary before the switch, it is in $(scratch_dir "$front")/mode-switch-summary.md: read it first."
    [ -n "$(clear_command "$cfg" "$front")" ] || msg="$msg Your previous conversation is still there: follow only this mode's prompt from now on."
    msg="$msg Start with the startup."
  elif [ "$resume" = 2 ]; then
    msg="$msg WARNING: you are BACK after a restart, with your previous conversation. Every terminal of the team was reopened and the handles above are the new ones; the dispatches that were in flight point to terminals that no longer exist. Before talking to the user, follow the section \"Coming back with your memory\" of your prompt. Start there."
    [ "${ORCA_ROLES_RELAUNCH:-}" = 1 ] && msg="$msg You were reopened by your own launch.sh --reopen (an Orca restart had left you without the kit's settings)."
  elif cm="$(coordinated_marker)" && [ -f "$cm" ]; then   # a coordinator will dispatch the task: an idle front role with no dialog open is what lets it in
    msg="$msg This worktree was opened by a coordinator that will send you its task as an Orca dispatch (see your section \"Working under a coordinator\"). Do the startup and stop there: do not start phase 1, do not infer a goal from the branch, a linked issue or the Runs, and open no question dialog, because an open dialog blocks the dispatch. End your turn with one line saying you are waiting for the coordinator's task. If the user writes in this tab first, the user takes precedence."
  else
    msg="$msg Start with the startup."
  fi
  printf '%s' "$msg"
}
# The front role's first message while the worktree has no mode yet: ask the user which mode to start in.  planner_ask_msg <config>
planner_ask_msg() {
  local cfg="$1" lang msg sug
  sug="$(jq -r '.settings.mode // "programmer"' "$cfg" 2>/dev/null)"; case " $MODE_IDS " in *" $sug "*) ;; *) sug=programmer;; esac
  msg="You are the local coordinator of the orca-roles kit in this worktree, and no mode has been chosen yet. Do not start any work and do not read any prompt before the mode is chosen: once the user chooses, the kit sends you your role message for that mode."
  lang="$(setting "$cfg" language auto)"
  if [ "$lang" != auto ] && [ -n "$lang" ]; then msg="$msg Always reply to the user in $lang, whatever language they write in."
  else msg="$msg Reply to the user in the language they write in."; fi
  msg="$msg Ask the user as plain text in your reply (never with the AskUserQuestion tool or any selection dialog: a stray Enter would pick an option) which mode to start in, offering these four: programmer (plan and build code with a team: Planner, Researcher, Dev, Tester, Plan-Reviewer, Code-Reviewer, E2E-Tester, Deployer), academic-research (write a research paper with a team: Planner and the phase's roles), pr-reviewer (review a pull request or a diff with the review lenses), and quick (simple changes with a small team: you plan with the user, Dev and the Tester build and test; no Planner and no audits). Suggest $sug, the configured one. Then end your turn and wait for the user's typed answer."
  msg="$msg When the user chooses, run \`~/.orca-roles/bin/launch.sh --mode <mode>\` from the worktree with the chosen mode and end your turn: the kit opens the team and sends you your role message for it."
  printf '%s' "$msg"
}
# Every handle the front role's tab has had in this worktree (the name of the file is the one the Planner's had before the local coordinator):
# <git dir>/orca-roles.planner-handles, one per line, no duplicates, atomic. If the file does not exist it is first seeded with the front
# role's values of orca-roles.kicked and orca-roles.env.  With an empty handle it only seeds.
planner_history_add() {  # planner_history_add <git dir> <handle>
  local f="$1/orca-roles.planner-handles" tmp="$1/orca-roles.planner-handles.tmp.$$" fv m
  m="$(mode_of --saved "$1/orca-roles.config.json" 2>/dev/null)" || m=programmer
  fv="$(front_var "$m" "$1")"
  {
    if [ -f "$f" ]; then cat "$f"
    else
      grep "^$fv=" "$1/orca-roles.kicked" 2>/dev/null | head -1 | cut -d= -f2-
      grep "^$fv=" "$1/orca-roles.env" 2>/dev/null | head -1 | cut -d= -f2-
    fi
    printf '%s\n' "$2"
  } | awk 'NF && !seen[$0]++' > "$tmp" && mv "$tmp" "$f"
}
# The Run most recently updated that is still bound to a previous tab of the front role (a handle in the history other than the current one):
# prints "<id><TAB><old handle><TAB><objective>" (objective on one line, up to 120 characters), nothing if there is none or no history,
# and nothing while a Run is bound to the current handle (Orca keeps one Run per tab: binding another would release it);
# 1 if the Runs cannot be listed.  stale_run <git dir> <current front role handle>
stale_run() {
  local hist="$1/orca-roles.planner-handles" cursor="" js runs="[]" i=0
  [ -f "$hist" ] || return 0
  while [ "$i" -lt 50 ]; do
    if [ -n "$cursor" ]; then js="$(orca orchestration run-list --json --full --cursor "$cursor" 2>/dev/null)" || return 1
    else js="$(orca orchestration run-list --json --full 2>/dev/null)" || return 1; fi
    runs="$(printf '%s' "$js" | jq -c --argjson acc "$runs" '$acc + [(.result.runs // [])[]]' 2>/dev/null)" || return 1
    cursor="$(printf '%s' "$js" | jq -r '.result.nextCursor // empty' 2>/dev/null)" || return 1
    i=$((i + 1)); [ -n "$cursor" ] || break
  done
  printf '%s' "$runs" | jq -r --argjson hs "$(jq -R . "$hist" | jq -s .)" --arg cur "$2" \
    'if any(.[]; .coordinator_handle == $cur) then empty else [.[] | select(.coordinator_handle as $h | $h != $cur and ($hs | index($h)))] | max_by(.updated_at) // empty end
     | "\(.id)\t\(.coordinator_handle)\t\((.objective // "") | gsub("[\t\n\r]"; " ") | .[0:120])"' 2>/dev/null || return 1
}
# The line each role gets outside its conversation, which clearing the conversation does not erase: claude in its system prompt
# (--append-system-prompt), codex as developer_instructions, custom through {anchor} / $ORCA_ROLES_ANCHOR if its command uses them.
# The role itself arrives as a message, so when that message is gone the agent asks the kit for it again.  role_anchor <config> <role>
# Workers (every role but the front role, the local coordinator: the Planner is one) also get the English rule, because the user's own
# language setting would otherwise win over the prompt.
role_anchor() {
  local en=""
  [ "$2" != "$(front_of "$1")" ] && en=" Always write in English (screen, worker_done, ask, escalation), whatever language the task, the repo or your settings use; repo artifacts (code, commits, docs) follow the repo's own language."
  printf '%s' "You are the $(title_of "$1" "$2") role of the orca-roles kit in this Orca workspace. Your role, its instructions and the team's handles arrive as a message in this conversation. If the conversation has no such message (for example after /clear or /new), before doing anything else run \`$(kit_env)$KIT/bin/clean.sh --msg $2\` in this worktree and follow the message it prints as if it had been sent to you.$en"
}
# A role's parameters (defaults.params + roles.<role>.params) as "k=v, k=v"
params_of() { jq -r --arg r "$2" '((.defaults.params // {}) * (.roles[$r].params // {})) | to_entries | map("\(.key)=\(.value)") | join(", ")' "$1"; }
# Marks a role's folder (a pair tree) as trusted the way launch.sh does for the worktree.  trust_role_in <dir> <config> <role>
trust_role_in() {
  ( cd "$1" || exit 0
    case "$(rstr "$2" "$3" agent)" in claude|"") trust_folder;; esac
    trust_custom_roles "$2" "$3" )
}
# A role's extra instructions for this worktree only (the Planner saves them with its skill): <git dir>/orca-roles.notes/<role>.md
notes_file() { local gd; gd="$(team_git_dir)" || return 0; echo "$(cd "$gd" && pwd)/orca-roles.notes/$1.md"; }
# The git dir that holds the team's files: the current one, or, in a pair tree (pair-tree.sh), the worktree's, named by its marker.
team_git_dir() {
  local gd m; gd="$(git_here absolute-git-dir)" || return 1
  if [ -s "$gd/orca-roles.pair" ]; then m="$(head -1 "$gd/orca-roles.pair")"; [ -n "$m" ] && [ -d "$m" ] && gd="$m"; fi
  printf '%s\n' "$gd"
}
# A worker's scratch folder: fixed per worktree and role, OUTSIDE the worktree ($KIT/tmp/<project>-<hash of the git dir>/<role>).
# The agents reuse it and never delete anything in it; the kit never empties it. It is outside the worktree because
# jest, vitest and eslint collect copies of the project that live inside it and none honors .gitignore.  scratch_dir <role>
scratch_dir() {
  local gd h proj role="${1:-}"
  [ -n "$role" ] || return 1
  gd="$(team_git_dir)" || gd="$(pwd -P)"
  h="$(printf '%s' "$gd" | { shasum 2>/dev/null || sha1sum 2>/dev/null || cksum; } | cut -d' ' -f1 | cut -c1-10)"
  proj="$(project_name .)"
  case "$proj" in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) proj="$(printf '%s\n' "$proj" | tr -c 'A-Za-z0-9._\n-' '_')";; esac
  case "$role" in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) role="$(printf '%s' "$role" | tr -c 'A-Za-z0-9._-' '_')";; esac
  [ -n "$h" ] && [ -n "$proj" ] || return 1
  printf '%s' "$KIT/tmp/$proj-$h/$role"
}
# The ignored entries of <top> (dependencies such as node_modules or a venv) linked into <dest>, which holds a copy of <top>'s files: never copied;
# caches and build outputs stay out (a run would write into the original's, or load its built code). Prints each linked path, relative.  link_ignored_entries <top> <dest>
link_ignored_entries() {
  local top="$1" dest="$2" p parent
  while IFS= read -r p; do
    p="${p%/}"; [ -n "$p" ] || continue
    # .opencode (OpenCode's per-checkout agents, plugins and their dependencies, and an older kit's agent files) is never linked: OpenCode in the tree would load or write the worktree's
    case "/$p/" in */.opencode/*) continue;; esac
    case "/$p" in */__pycache__|*/.pytest_cache|*/.mypy_cache|*/.ruff_cache|*/.DS_Store|*/dist|*/build|*/out|*/coverage|*/htmlcov|*/target|*/.tox|*/.nox|*/.nyc_output|*/.next|*/.nuxt|*/.svelte-kit|*/.turbo|*/.parcel-cache|*/.gradle|*/.eggs) continue;; esac
    parent="$(dirname "$p")"
    [ -d "$dest/$parent" ] && [ ! -e "$dest/$p" ] && [ ! -L "$dest/$p" ] || continue
    ln -s "$top/$p" "$dest/$p" && printf '%s\n' "$p"
  done < <(git -C "$top" ls-files -o -i --exclude-standard --directory 2>/dev/null)
  return 0
}
# Why the linked ignored entry <top>/<path> points back into <top> (an editable install in a virtualenv, a workspace link inside node_modules), or nothing.  link_back_reason <top> <path>
link_back_reason() {
  local TOP="$1" p="$2" src RAW why="" f l t
  src="$TOP/$p"; RAW="$(git -C "$TOP" rev-parse --show-toplevel)"
  if [ -f "$src/pyvenv.cfg" ]; then
    f="$(find "$src" -maxdepth 6 -path '*site-packages/*' \( -name '*.pth' -o -name '__editable__*' -o -name direct_url.json \) -type f \
      -exec grep -lF -e "$TOP" -e "$RAW" {} + 2>/dev/null | head -1)"
    [ -n "$f" ] && why="editable install (${f#"$src"/})"
  fi
  if [ -z "$why" ] && [ "$(basename "$p")" = node_modules ]; then
    while IFS= read -r l; do
      t="$(cd "$(dirname "$l")" 2>/dev/null && cd "$(readlink "$l")" 2>/dev/null && pwd -P)" || continue
      case "$t/" in "$src"/*) ;; "$TOP"/*) why="workspace link (${l#"$src"/} -> ${t#"$TOP"/})"; break;; esac
    done < <(find "$src" -mindepth 1 -maxdepth 2 -type l 2>/dev/null)
  fi
  [ -z "$why" ] || printf '%s\n' "$why"
  return 0
}
# The kit's own files a worker must not edit (paths relative to $KIT), one per line; tmp/ and backup/ stay writable.
kit_protected_paths() {
  printf '%s\n' 'prompts/**' 'roles/**' 'bin/**' 'plugin/**' 'plugins/**' 'shim/**' 'pw/**' 'mcp/**' 'browsers/**' 'browser/**' \
    config.json config.default.json trusted.list .manifest .installed VERSION
}
# Claude Code deny rules that keep a worker from editing the kit itself: its prompts, scripts, plugin, roles and configuration.
# --add-dir gives write access in auto mode (additional directories follow the permission mode), and every future worker
# reads these files.  Not the whole $KIT: scratch folders live in $KIT/tmp and must stay writable (a deny cannot be undone by an allow).
# "//" anchors the pattern at the filesystem root; Claude Code applies a rule written through a symlinked directory at its real location too.
kit_deny_rules() {
  local k="${KIT#/}" d
  while IFS= read -r d; do printf 'Edit(//%s/%s)\n' "$k" "$d"; done < <(kit_protected_paths)
}
# A worker's message when its tab was reopened with its previous conversation after a restart.  worker_back_msg <config> <role> <handle>
worker_back_msg() {
  printf '%s' "You are back after a restart of the computer or of Orca, with your previous conversation; your role and its instructions still apply. Your terminal handle is now $3. Whatever task you were doing was interrupted and its dispatch is gone: do not continue it on your own. Look at your worktree (git status, git diff --stat) to remember what you had already changed, and wait for $(front_label "$(front_of "$1")") to send it again. If you had no task, stay idle. Reply only with one line saying whether you had a task in progress and what it was."
}
# A role's common-rules file: its "common" field (accepts ~, {kit}, {home}) if the file exists (else a warning), else the mode's common-workers.md
common_of() {
  local cm; cm="$(rstr "$1" "$2" common)"
  if [ -n "$cm" ]; then
    cm="$(expand_path "$cm")"
    [ -f "$cm" ] || { echo "orca-roles: the common file of role '$2' does not exist ($cm); using common-workers.md" >&2; cm=""; }
  fi
  [ -n "$cm" ] || cm="$(prompts_dir_of "$1")/common-workers.md"
  printf '%s' "$cm"
}
# A worker's startup message.  worker_msg <config> <role>
# If the role has instructions for this worktree, they go inside the message: that way they survive context cleanup.
# Agents other than Claude are also told to run Orca's commands in the foreground: an Antigravity worker ran its worker_done as a
# background subagent task that never finished, so Orca never got its report.
# The role's "common" field (a path; accepts ~, {kit} and {home}) replaces the mode's common-workers.md, e.g. with the compact common-peon.md
# for small models; if that file does not exist, the standard one is used and a warning goes to stderr.
worker_msg() {
  local p n b notes="" fg="" cm short=""; p="$(params_of "$1" "$2")"; p="${p:+$p, }scratchDir=$(scratch_dir "$2")"; b="$(instance_base "$1" "$2")"; n="$(notes_file "${b:-$2}")"
  case "$(rstr "$1" "$2" agent)" in claude|"") ;; *) fg=" Run every orca orchestration command (and its CLI under any other name) in the foreground, as a direct shell command, and wait for it to finish: never as a background task or through a subagent, or Orca will not get your report.";; esac
  [ -n "$n" ] && [ -s "$n" ] && notes=" Additional instructions for this worktree, which take precedence over your prompt if they conflict: $(tr '\n' ' ' < "$n" | sed 's/  */ /g; s/ $//')"
  cm="$(common_of "$1" "$2")"
  [ "$(flow_report_body "$1")" = short ] && short=" Flow override, for the body of your worker_done only (this replaces the \"complete, self-contained, never point to scratchDir\" rule of your common prompt): keep the body to at most ~8 lines with the outcome, the files changed, how you verified it and its result, and the open issues; write the full detail to a file in your scratchDir and name its absolute path in the body. Your ask and escalation messages stay full sentences."
  if [ "$(rstr "$1" "$2" agent)" = opencode ]; then   # the role and the common rules are the agent's system prompt (opencode-prepare.sh)
    printf '%s' "Your role ($(title_of "$1" "$2")) and its rules are in your system prompt (agent orca-$2); follow them to the letter.${p:+ Configuration parameters: $p.}$fg$short$notes"
    return
  fi
  printf '%s' "Read $cm and $(prompt_of "$1" "$2") and adopt that role from now on. Follow its instructions to the letter.${p:+ Configuration parameters: $p.}$fg$short$notes"
}
# A path with ~, {kit} or {home} expanded
# What the kit never lets the Planner do while its superpowers folder is loaded: the kit's Planner coordinates through Orca (no worktrees,
# no subagents of its own, no implementation, merge or push). agent.sh applies it whenever $KIT/plugins/superpowers is loaded, whatever the
# role's own disallowedTools say.  superpowers_deny → one tool or Skill(...) per line
superpowers_deny() {
  printf '%s\n' 'Skill(superpowers:subagent-driven-development)' 'Skill(superpowers:executing-plans)' 'Skill(superpowers:dispatching-parallel-agents)' \
    'Skill(superpowers:requesting-code-review)' 'Skill(superpowers:using-git-worktrees)' 'Skill(superpowers:finishing-a-development-branch)' \
    'Skill(superpowers:writing-skills)' 'Skill(superpowers:diagnosing-superpowers)' EnterWorktree ExitWorktree Agent Task
}
# Skills the Planner does not use (it is a worker in every mode that has it): it keeps brainstorming, writing-plans and receiving-code-review, and the kit's
# team skill is the local coordinator's.  planner_skill_deny → one Skill(...) per line
planner_skill_deny() {
  printf '%s\n' 'Skill(superpowers:verification-before-completion)' 'Skill(superpowers:test-driven-development)' 'Skill(superpowers:systematic-debugging)' \
    'Skill(superpowers:using-superpowers)' 'Skill(orca-roles:team)'
}
# Skills the local coordinator leaves to the Planner (planning and rulings) and to the workers (test-driven development, debugging).  local_coordinator_skill_deny → one Skill(...) per line
local_coordinator_skill_deny() {
  printf '%s\n' 'Skill(superpowers:brainstorming)' 'Skill(superpowers:writing-plans)' 'Skill(superpowers:receiving-code-review)' \
    'Skill(superpowers:test-driven-development)' 'Skill(superpowers:systematic-debugging)'
}
# What the local coordinator's tab takes from a mode when agent.sh starts it: its model, and whether its planning skills are blocked (in every mode but quick).
# A mode switch or choice that changes it closes that tab and opens a new one (launch.sh).  front_launch_key <config> <mode>
front_launch_key() { printf '%s|%s\n' "$(role_model "$1" local-coordinator "$2")" "$([ "$2" = quick ] && echo open || echo blocked)"; }
# The reviewers (Plan-Reviewer, Code-Reviewer, pr-reviewer's Verifier) verify plans, code and findings themselves and must never dispatch a gate's reviewer subagents or subagents of their own. The list lives in the kit so a
# user's own disallowedTools (which replace a config default) cannot drop it.  reviewer_deny → one tool per line. The on-demand Auditor (auditor.sh), which is not a team role, uses the same list.
reviewer_deny() { printf '%s\n' Agent Task; }
# Same trust as the teams (settings.trust, default "worktree"); with "never" Claude asks, as the user is in this tab anyway. A folder
# Claude Code already knows keeps its entry: only the flag is set and it is not recorded, so forget-trust.sh never touches it (it only removes the flag the kit set, and an entry only when nothing else is in it).
trust_launch_folder() { # trust_launch_folder <merged config file>
if [ "$(trust_of "$1")" = worktree ]; then
  D="$(pwd -P)"; KNOWN="$(jq -r --arg d "$D" '.projects[$d] | if . == null then "no" elif .hasTrustDialogAccepted == true then "trusted" else "yes" end' "$HOME/.claude.json" 2>/dev/null)" || KNOWN=""
  case "$KNOWN" in
    no) trust_folder;;
    yes) safe_json_edit "$HOME/.claude.json" '.projects[$dir].hasTrustDialogAccepted = true' "$D" "$HOME/.claude.json.lock" \
           && echo "Marked $D as trusted for Claude Code (its existing entry is kept; forget-trust.sh does not touch it).";;
  esac
fi
}
expand_path() { local p="${1/#\~/$HOME}"; p="${p//\{kit\}/$KIT}"; printf '%s' "${p//\{home\}/$HOME}"; }
# Command that opens a new conversation in a role's agent (the clearCommand field, or the agent's own)
clear_command() {
  local c; c="$(rstr "$1" "$2" clearCommand)"
  if [ -n "$c" ]; then echo "$c"; return; fi
  case "$(rstr "$1" "$2" agent)" in claude|"") echo "/clear";; codex|opencode) echo "/new";; *) ;; esac
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
# The same servers in OpenCode's format, as one JSON object {"<name>": {...}} for its "mcp": {"servers": ...}: a server with a url is
# {"type": "remote", "url", "headers"?}, one with a command {"type": "local", "command": [command, args...], "environment"?}; any other is
# left out (as codex_mcp_overrides does).  opencode_mcp_servers <mcp file>
opencode_mcp_servers() {
  jq -c '(.mcpServers // {}) | with_entries(.value |= (
      if (.url | type) == "string" then {type: "remote", url: .url} + (if (.headers | type) == "object" then {headers: .headers} else {} end)
      elif (.command | type) == "string" then {type: "local", command: ([.command] + (if (.args | type) == "array" then .args | map(tostring) else [] end))}
        + (if (.env | type) == "object" then {environment: .env} else {} end)
      else null end)) | with_entries(select(.value != null))' "$1"
}
# Project name: the main repo's folder (not the worktree's); if it is not a repo, the given folder.  project_name <folder>
project_name() {
  local common gcmd=(git rev-parse --git-common-dir)
  case "$1" in .|"$PWD") gcmd=(git_here common-dir);; esac
  if common="$(cd "$1" 2>/dev/null && "${gcmd[@]}" 2>/dev/null)"; then
    common="$(cd "$1" && cd "$common" && pwd)"; basename "$(dirname "$common")"
  else basename "$(cd "$1" && pwd)"; fi
}
# The saved browser session of an identity of a project: ~/.orca-roles/browser/<project>/<identity>.json (identity default: "default").
# An identity is lowercase letters, digits and hyphens, starting with a letter or digit; anything else is refused (1).  session_file <project> [<identity>]
session_file() {
  local id=default
  if [ $# -ge 2 ]; then id="$2"; fi
  case "$id" in
    ''|-*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) echo "ERROR: invalid identity '$id': use lowercase letters, digits and hyphens, starting with a letter or digit." >&2; return 1;;
  esac
  echo "$KIT/browser/$1/$id.json"
}
# The host (lowercase, without userinfo and port) and the origin (scheme://host[:port], default port dropped) of an http(s) URL,
# as two lines. Refuses (1) anything that is not http(s) with a host.  url_host_origin <url>
url_host_origin() {
  local url="$1" scheme rest auth host port origin
  case "$url" in http://?*|https://?*) ;; *) return 1;; esac
  scheme="${url%%://*}"; rest="${url#*://}"; auth="${rest%%[/?#]*}"; auth="${auth##*@}"
  case "$auth" in
    \[*) host="${auth%%]*}]"; port="${auth#"$host"}"; port="${port#:}";;
    *) host="${auth%%:*}"; port=""; case "$auth" in *:*) port="${auth#*:}";; esac;;
  esac
  [ -n "$host" ] || return 1
  host="$(lower_ascii "$host")"
  case "$scheme:$port" in http:80|https:443) port="";; esac
  origin="$scheme://$host"; [ -z "$port" ] || origin="$origin:$port"
  printf '%s\n%s\n' "$host" "$origin"
}
# 0 if a saved session file has a cookie for the URL's host (by host or domain, leading dot included) or localStorage for its origin.
# session_matches <state-file> <url>
session_matches() {
  local ho host origin
  ho="$(url_host_origin "$2")" || return 1
  host="$(printf '%s\n' "$ho" | sed -n 1p)"; origin="$(printf '%s\n' "$ho" | sed -n 2p)"
  jq -e --arg host "$host" --arg origin "$origin" '
    def hostmatch($d): ($d // "") as $d | if ($d | startswith(".")) then ($host == $d[1:] or ($host | endswith($d))) else $host == $d end;
    def norm: ascii_downcase | sub("^(?<s>http://[^/]*):80$"; .s) | sub("^(?<s>https://[^/]*):443$"; .s);
    ((.cookies // []) | map(select(hostmatch(.domain))) | length > 0)
    or ((.origins // []) | map(select((.origin // "" | norm) == $origin and ((.localStorage // []) | length) > 0)) | length > 0)' "$1" >/dev/null 2>&1
}
# Moves the single-session file of earlier versions (browser/<project>.json) to browser/<project>/default.json when that one is missing or
# an empty stub; a destination with a session is never overwritten (the old file stays and a warning goes to stderr).  migrate_session <project>
migrate_session() {
  local old="$KIT/browser/$1.json" new="$KIT/browser/$1/default.json"
  [ -f "$old" ] || return 0
  if [ -f "$new" ] && ! jq -e '((.cookies // []) | length) + ((.origins // []) | length) == 0' "$new" >/dev/null 2>&1; then
    echo "WARNING: $old was not migrated: $new already has a session. Delete $old if you no longer need it." >&2
    return 0
  fi
  mkdir -p "$KIT/browser/$1" && mv -f "$old" "$new"
}
# A role's context for the mcpServers placeholders; exports ORCA_ROLES_WORKTREE/PROJECT/EVIDENCE_DIR/BROWSER_STATE.  role_context <config> <role> <worktree>
role_context() {
  ORCA_ROLES_WORKTREE="$(cd "$3" && pwd)"
  ORCA_ROLES_PROJECT="$(project_name "$3")"
  ORCA_ROLES_EVIDENCE_DIR="$(jq -r --arg r "$2" '.roles[$r].params.evidenceDir // .roles["e2e-tester"].params.evidenceDir // .defaults.params.evidenceDir // "qa-evidence"' "$1")"
  migrate_session "$ORCA_ROLES_PROJECT"
  ORCA_ROLES_BROWSER_STATE="$(session_file "$ORCA_ROLES_PROJECT")"
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
# A file's permission bits in octal (GNU stat, then BSD stat); empty if they cannot be read.  file_mode_of <file>
file_mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
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
    for _ in $(seq 1 20); do mkdir "$lock" 2>/dev/null && { got=1; break; }; pace 0.25; done
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
      mode="$(file_mode_of "$f")"
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
# The kit's Claude Code SessionStart hook (bin/session-hook.sh: re-binds a reopened tab's Orca Runs), registered in the user-level settings.json
# because a tab Orca resumes itself carries none of the kit's flags. settings.sessionHook (global config, true if unset) turns it off.
session_hook_enabled() {
  local c="$KIT/config.json"; [ -f "$c" ] || c="$KIT/config.default.json"
  [ "$(setting "$c" sessionHook true 2>/dev/null)" != false ]
}
SESSION_HOOK_ADD='($dir + "/bin/session-hook.sh") as $c
  | if ([.hooks.SessionStart[]?.hooks[]? | select((.command // "") | endswith("/bin/session-hook.sh"))] | length) > 0
    then .hooks.SessionStart |= map(if (.hooks | type) == "array" then .hooks |= map(if ((.command // "") | endswith("/bin/session-hook.sh")) then .command = $c else . end) else . end)
    else .hooks.SessionStart = ((.hooks.SessionStart // []) + [{hooks: [{type: "command", command: $c, timeout: 15}]}]) end'
SESSION_HOOK_DEL='if (.hooks.SessionStart? | type) == "array" then
    .hooks.SessionStart |= (map(if (.hooks | type) == "array" then .hooks |= map(select(((.command // "") | endswith("/bin/session-hook.sh")) | not)) else . end)
      | map(select((.hooks | type) != "array" or (.hooks | length) > 0)))
    | (if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end)
    | (if (.hooks | length) == 0 then del(.hooks) else . end)
  else . end'
# Adds (or points to this kit) the SessionStart entry in ${ORCA_ROLES_CLAUDE_SETTINGS:-~/.claude/settings.json}, keeping everything else.  0 = it is there
# (SESSION_HOOK_CHANGED=1 if this call wrote it); 1 = the file is not valid JSON or could not be written (nothing is lost).  ensure_session_hook [--backup]
ensure_session_hook() {
  local f="${ORCA_ROLES_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}" backup=0 kit rc=0
  [ "${1:-}" = --backup ] && backup=1
  SESSION_HOOK_CHANGED=0   # read by install.sh
  [ -e "$KIT/.installed" ] || return 0   # only an installed kit registers itself: a clone must not take the entry over
  kit="$(cd "$KIT" 2>/dev/null && pwd)" || kit="$KIT"
  if [ ! -e "$f" ]; then mkdir -p "$(dirname "$f")" 2>/dev/null && printf '{}\n' > "$f" || return 1; fi
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || return 1
  if [ "$(jq -S -c . "$f")" = "$(jq -S -c --arg dir "$kit" "$SESSION_HOOK_ADD" "$f" 2>/dev/null)" ]; then return 0; fi
  [ "$backup" = 0 ] || cp "$f" "$f.orca-roles-bak" 2>/dev/null || true
  safe_json_edit "$f" "$SESSION_HOOK_ADD" "$kit" "$f.lock" || rc=$?
  # shellcheck disable=SC2034
  case "$rc" in 0) SESSION_HOOK_CHANGED=1;; 3) ;; *) return 1;; esac
  return 0
}
# ensure_session_hook with the WARNING a failure deserves (the callers go on either way).  ensure_session_hook_or_warn [--backup]
ensure_session_hook_or_warn() {
  local f="${ORCA_ROLES_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
  ensure_session_hook "$@" && return 0
  if [ -f "$f" ] && ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then echo "WARNING: $f is not valid JSON; the kit's SessionStart hook was not added."
  else echo "WARNING: could not write $f; the kit's SessionStart hook was not added."; fi
  return 0
}
# Removes the kit's SessionStart entry (and the arrays it empties); nothing if the file is missing or invalid.  remove_session_hook
remove_session_hook() {
  local f="${ORCA_ROLES_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}" rc=0   # rc: a failed edit leaves the file as it was
  [ -f "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1 || return 0
  safe_json_edit "$f" "$SESSION_HOOK_DEL" "" "$f.lock" || rc=$?
  return 0
}
# Whether the kit marks the worktree as trusted: "worktree" (it does) or "never" (the agents ask the user). settings.trust if set; without it,
# "worktree" in every mode, as before settings.trust existed ("never" is opt-in, e.g. for other people's branches in pr-reviewer).
# An invalid value is a warning on stderr and counts as "never".  trust_of <config>
trust_of() {
  local t
  t="$(jq -r '(.settings // {}) | (.trust // "") | if type == "string" then . else tojson end' "$1" 2>/dev/null)" || t=""
  case "$t" in
    worktree|never) printf '%s\n' "$t";;
    "") echo worktree;;
    *) echo "Warning: settings.trust must be \"worktree\" or \"never\" (got '$t'); using \"never\"." >&2; echo never;;
  esac
}
# The folders the kit marked as trusted in ~/.claude.json, one physical path per line (forget-trust.sh removes them).
trusted_list() { echo "$KIT/trusted.list"; }
trust_record() {  # trust_record <dir>: adds it once; never fatal
  local f; f="$(trusted_list)"
  { mkdir -p "$(dirname "$f")" && { grep -qxF -- "$1" "$f" 2>/dev/null || printf '%s\n' "$1" >> "$f"; }; } 2>/dev/null \
    || echo "Warning: could not record $1 in $f; forget-trust.sh will not find it." >&2
  return 0
}
# Claude Code asks "Do you trust the files in this folder?" the first time it starts in a folder, and a tab stuck in that dialog never
# gets its role. Registering the kit in the project is that answer, so the worktree is marked as trusted before the agents start.
# Never fatal: on a failure ~/.claude.json is left as it was and a warning is printed.
trust_folder() {
  local link="$HOME/.claude.json" d rc=0; d="$(pwd -P)"
  safe_json_edit "$link" '.projects[$dir] = ((.projects[$dir] // {}) + {hasTrustDialogAccepted: true})' "$d" "$link.lock" || rc=$?
  case "$rc" in
    0) trust_record "$d"; echo "Marked $d as trusted for Claude Code, so the trust dialog does not stop the agents.";;
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

# Orca's own binary (in node mode) and its runtime client, from the 'orca' on the PATH: "<binary>|<runtime-client.js>" (macOS app), else nothing and 1.
# On WSL (Orca for Windows) the binary is Orca.exe, found through orca-ide's ORCA_WIN_LAUNCHER line, and the result ends in "|wsl": the runtime client is a Windows path.
orca_app_node() {
  local p l d app ide line v inst exe suf
  if p="$(type -P orca 2>/dev/null)" && case "$p" in /*) true;; *) false;; esac; then
    while [ -L "$p" ]; do
      l="$(readlink "$p")" || break
      case "$l" in /*) p="$l";; *) d="$(dirname "$p")"; p="$d/$l";; esac
    done
    case "$p" in
      *.app/Contents/Resources/bin/orca)
        app="${p%/Contents/Resources/bin/orca}"
        [ -x "$app/Contents/MacOS/Orca" ] && [ -f "$app/Contents/Resources/app.asar.unpacked/out/cli/runtime-client.js" ] || return 1
        printf '%s|%s\n' "$app/Contents/MacOS/Orca" "$app/Contents/Resources/app.asar.unpacked/out/cli/runtime-client.js"
        return 0;;
    esac
  fi
  is_wsl || return 1
  ide="$(orca_ide_path)" || return 1
  line="$(grep -m1 '^ORCA_WIN_LAUNCHER=' "$ide" 2>/dev/null)" || return 1
  v="${line#*\'}"; v="${v%%\'*}"
  suf='\resources\bin\orca.exe'
  [ "${#v}" -gt "${#suf}" ] && [ "$(printf '%s' "${v:${#v}-${#suf}}" | tr 'A-Z' 'a-z')" = "$suf" ] || return 1
  inst="${v:0:${#v}-${#suf}}"
  exe="$(wslpath -u "$inst\\Orca.exe" 2>/dev/null)" || return 1
  [ -n "$exe" ] && [ -f "$exe" ] && [ -x "$exe" ] || return 1
  printf '%s|%s|wsl\n' "$exe" "$inst\\resources\\app.asar.unpacked\\out\\cli\\runtime-client.js"
}

# A path as the kit's shell sees it: a Windows UNC path (\\wsl.localhost\Ubuntu\...) as a Linux path; any other path unchanged.
local_path() {
  local c
  case "$1" in
    '\\'*) if command -v wslpath >/dev/null 2>&1 && c="$(wslpath -u "$1" 2>/dev/null)" && [ -n "$c" ]; then printf '%s\n' "$c"; else printf '%s\n' "$1"; fi;;
    *) printf '%s\n' "$1";;
  esac
}

# Wakes a tab Orca keeps asleep after a restart: wake_tab <worktreeId> <tabId> <leafId>. Returns 0 woken (stdout empty), 1 failed (stdout: the reason), 2 unavailable here.
wake_tab() {
  local n bin rc rcl err wenv
  if [ -n "${ORCA_ROLES_WAKE:-}" ]; then
    "$ORCA_ROLES_WAKE" "$@"; rc=$?
    case "$rc" in 0) return 0;; 2) return 2;; *) return 1;; esac
  fi
  n="$(orca_app_node)" || return 2
  bin="${n%%|*}"; rcl="${n#*|}"
  if [ "${rcl##*|}" = wsl ]; then
    rcl="${rcl%|wsl}"
    wenv="${WSLENV:-}"
    case ":$wenv:" in *:ELECTRON_RUN_AS_NODE:*|*:ELECTRON_RUN_AS_NODE/*) ;; *) wenv="${wenv:+$wenv:}ELECTRON_RUN_AS_NODE";; esac
    err="$(cd "$(dirname "$bin")" && ELECTRON_RUN_AS_NODE=1 WSLENV="$wenv" bounded_run 30 "wake-tab" "$bin" "$(wslpath -w "$KIT/bin/wake-tab.cjs")" "$rcl" "$@" 2>&1 >/dev/null)" && return 0
  else
    err="$(ELECTRON_RUN_AS_NODE=1 bounded_run 30 "wake-tab" "$bin" "$KIT/bin/wake-tab.cjs" "$rcl" "$@" 2>&1 >/dev/null)" && return 0
  fi
  printf '%s\n' "$err" | head -1
  return 1
}

# The tab and pane ids of a terminal handle, "<tabId> <leafId>" (what Orca restores); nothing if either is missing or the call fails.
tabs_of_handle() {
  orca terminal show --terminal "$1" --json 2>/dev/null | jq -r '[.. | objects | select((.tabId // "") != "" and (.leafId // "") != "")] | first | select(. != null) | "\(.tabId) \(.leafId)"' 2>/dev/null
  return 0
}
