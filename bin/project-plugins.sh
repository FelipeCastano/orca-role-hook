#!/usr/bin/env bash
# Reports, and installs on request, the plugins and MCP servers a project declares.
# Usage: project-plugins.sh status [<folder>] | project-plugins.sh install <plugin id> [<folder>]
#   <folder> defaults to the git top level of the current folder, else the current folder. Only .claude/settings.json,
#   .claude/settings.local.json and .mcp.json of <folder> are read (settings.local.json wins over settings.json per id).
#   status   one tab-separated line per declared plugin, in declared order (the kit's own plugins are not reported):
#              plugin <id> installed | disabled | invalid-id | unknown-marketplace
#              plugin <id> missing <source>            source: github:<repo>[#<ref>][ sparse:<paths>], git:<url>[#<ref>][ sparse:<paths>],
#                                                      url:<url>, file:<path>, directory:<path> or "installed marketplace <name>"
#              plugin <id> unsupported-source <why>    <why>: github+path, git+path, url+headers, url+headersHelper, settings, an unknown
#                                                      type, or "invalid <field>" when a value fails the allow-list checks
#            then one line per MCP server of .mcp.json whose command is not on the PATH (commands with ${...} are skipped):
#              mcp <name> missing-command <command>
#            then "error <reason>" lines. Marketplace sources claude can add as they are: github (repo, optional ref, optional sparsePaths),
#            git (url, optional ref, optional sparsePaths), url (no headers), file and directory. Every value that reaches a claude
#            argument is checked against an allow-list (ids and sources never start with "-"); control characters are printed as "?".
#            Exit 0: everything declared is installed and there is nothing to report; 2: something is
#            missing, disabled, unknown, unsupported, invalid or an mcp line; 1: any error line.
#   install  only for a plugin that status reports as missing: adds its marketplace when it is declared but not installed, then installs
#            the plugin, both with --scope user (nothing is written in <folder>). Prints "installed <id>" (0). Already installed: the same
#            (0); disabled: refuses (3), because install would re-enable it; not declared: 2; any other state: its status line (2);
#            a failure: its first error line (1). It never asks anything and only runs when called: whoever calls it asks the user first.
# Every claude call is cut after 60 seconds (ORCA_ROLES_PLUGINS_TIMEOUT).
set -uo pipefail
KIT="${KIT:-$HOME/.orca-roles}"; . "$KIT/bin/lib.sh"
case "${1:-}" in -h|--help) sed -n 2,23p "$0"; exit 0;; esac
CMD="${1:-}"; shift || true
ID=""
case "$CMD" in
  status) [ $# -le 1 ] || { sed -n 3,3p "$0" >&2; exit 1; }; FOLDER="${1:-}";;
  install) [ $# -ge 1 ] && [ $# -le 2 ] || { sed -n 3,3p "$0" >&2; exit 1; }; ID="$1"; FOLDER="${2:-}";;
  *) sed -n 3,3p "$0" >&2; exit 1;;
esac
if [ -z "$FOLDER" ]; then FOLDER="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
[ -d "$FOLDER" ] || { echo "project-plugins.sh: $FOLDER is not a folder" >&2; exit 1; }
cleanup() { local c; trap '' INT TERM; for c in $(pgrep -P $$ 2>/dev/null); do kill_tree "$c"; done; rm -rf "$T"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/orca-project-plugins.XXXXXX")"; trap cleanup EXIT; trap 'exit 130' INT TERM
TO="${ORCA_ROLES_PLUGINS_TIMEOUT:-60}"
case "$TO" in ''|*[!0-9]*|0*) echo "project-plugins.sh: ORCA_ROLES_PLUGINS_TIMEOUT must be a whole number of seconds; using 60" >&2; TO=60;; esac
first_line() { head -1 | tr '\t\r' '  '; }
# <name> <command...>: runs it in the background with stdout/err in $T/<name>.out/.err, kills it after $TO seconds. Sets RC and TIMED.
bounded() {
  local i="$1" pid sl MAXN=$((TO * 10)); shift
  [ -z "${ORCA_ROLES_TICK:-}" ] || MAXN="$(awk -v t="$TO" -v k="$ORCA_ROLES_TICK" 'BEGIN { printf "%d", t / k + 0.5 }')"
  rm -f "$T/$i.stop" "$T/$i.to"
  "$@" > "$T/$i.out" 2> "$T/$i.err" < /dev/null & pid=$!
  ( n=0; s0=$SECONDS; while [ ! -e "$T/$i.stop" ] && [ "$n" -lt "$MAXN" ] && [ $((SECONDS - s0)) -le "$TO" ]; do sleep "${ORCA_ROLES_TICK:-0.1}"; n=$((n + 1)); done; [ -e "$T/$i.stop" ] || { : > "$T/$i.to"; kill_tree $pid; } ) > /dev/null 2>&1 & sl=$!
  wait $pid 2>/dev/null; RC=$?
  : > "$T/$i.stop"; wait $sl 2>/dev/null
  TIMED=0; [ -f "$T/$i.to" ] && TIMED=1
  return 0
}
# Control characters (except the tab and newline that separate fields and lines) never reach the terminal: they become "?"
clean() { LC_ALL=C tr '\000-\010\013-\037\177' '?'; }
err() { printf '%s\n' "$*" | clean >&2; }
ERRORS=""; add_error() { ERRORS="$ERRORS$1"$'\n'; }

# The two settings files: each one is its JSON, or {} when missing or unusable (then ignored, with an error line)
read_settings() {  # read_settings <relative file> <output>
  local f="$FOLDER/$1"
  printf '{}' > "$2"
  [ -f "$f" ] || return 0
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then add_error "error $1 is not valid JSON"; return 0; fi
  if ! jq -e '(has("enabledPlugins") | not) or (.enabledPlugins | type) == "object"' "$f" >/dev/null 2>&1; then add_error "error $1 enabledPlugins is not an object"; return 0; fi
  cp "$f" "$2"
}
read_settings .claude/settings.json "$T/p.json"
read_settings .claude/settings.local.json "$T/l.json"

# Declared plugins, compared with claude: $T/plugins.tsv has one line per plugin: id, state, source shown, "installed" if its
# marketplace is installed, the CLI source to add (with its #ref), the sparse paths (space separated); fields never empty: "-".
# Every value that reaches a claude argument is validated here (nothing that starts with "-" gets through): see okid and resolve.
PLUGINS_OK=1
compute_plugins() {
  local n row
  : > "$T/plugins.tsv"
  command -v claude >/dev/null 2>&1 || { add_error "error claude not found"; PLUGINS_OK=0; return 0; }
  n="$(jq -r -s '((.[0].enabledPlugins // {}) * (.[1].enabledPlugins // {})) | to_entries | map(select(.value == true)) | length' "$T/p.json" "$T/l.json")"
  [ "$n" != 0 ] || return 0
  bounded list claude plugin list --json
  if [ "$TIMED" = 1 ]; then add_error "error claude timed out"; PLUGINS_OK=0; return 0; fi
  if [ "$RC" != 0 ]; then
    row="$(first_line < "$T/list.err")"; [ -n "$row" ] || row="$(first_line < "$T/list.out")"; [ -n "$row" ] || row="claude plugin list exited $RC"
    add_error "error $row"; PLUGINS_OK=0; return 0
  fi
  jq -e 'type == "array"' "$T/list.out" >/dev/null 2>&1 || { add_error "error claude plugin list did not print a JSON list"; PLUGINS_OK=0; return 0; }
  # Only installs that count for this folder: user or managed ones, or project/local ones of this very folder (physical paths compared)
  PF="$(cd "$FOLDER" && pwd -P)"; MATCH='[]'
  while IFS= read -r pp; do
    [ -n "$pp" ] && [ -d "$pp" ] && [ "$(cd "$pp" && pwd -P)" = "$PF" ] && MATCH="$(jq -c --arg p "$pp" '. + [$p]' <<<"$MATCH")"
  done < <(jq -r '[.[] | objects | .projectPath | strings] | unique[]' "$T/list.out")
  bounded mk claude plugin marketplace list --json
  if [ "$TIMED" = 1 ]; then add_error "error claude timed out"; PLUGINS_OK=0; return 0; fi
  if [ "$RC" != 0 ]; then
    row="$(first_line < "$T/mk.err")"; [ -n "$row" ] || row="$(first_line < "$T/mk.out")"; [ -n "$row" ] || row="claude plugin marketplace list exited $RC"
    add_error "error $row"; PLUGINS_OK=0; return 0
  fi
  jq -e 'type == "array"' "$T/mk.out" >/dev/null 2>&1 || { add_error "error claude plugin marketplace list did not print a JSON list"; PLUGINS_OK=0; return 0; }
  jq -r --argjson here "$MATCH" --slurpfile list "$T/list.out" --slurpfile mk "$T/mk.out" --slurpfile p "$T/p.json" --slurpfile l "$T/l.json" '
    def dash: if . == null or . == "" then "-" else . end;
    def okid: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*\\z");
    def okrepo: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*\\z");
    def okurl: type == "string" and test("^(https://|http://|ssh://|git@)") and (test("[[:space:]]") | not);
    def okpath: type == "string" and test("^(/|\\./|~/)") and (test("\n") | not);
    def okref: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]*\\z");
    def oksparse: type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9._][A-Za-z0-9._/-]*\\z"));
    def given($k): has($k) and (.[$k] | type) != "null";
    def refpart: if given("ref") then "#" + .ref else "" end;
    def spstr: if (given("sparsePaths") and (.sparsePaths | length) > 0) then " sparse:" + (.sparsePaths | join(",")) else "" end;
    def spargs: if (given("sparsePaths") and (.sparsePaths | length) > 0) then (.sparsePaths | join(" ")) else "" end;
    # a declared marketplace source: {human, cli, sparse} when claude can add it as it is, else {bad: <what to report>}
    def resolve:
      (.source // "none") as $t
      | if $t == "github" or $t == "git" then
          if has("path") then {bad: "\($t)+path"}
          elif ($t == "github" and (.repo | okrepo | not)) then {bad: "invalid repo"}
          elif ($t == "git" and (.url | okurl | not)) then {bad: "invalid url"}
          elif (given("ref") and (.ref | okref | not)) then {bad: "invalid ref"}
          elif (given("sparsePaths") and (.sparsePaths | oksparse | not)) then {bad: "invalid sparse path"}
          else (if $t == "github" then .repo else .url end) as $loc
            | {human: "\($t):\($loc)\(refpart)\(spstr)", cli: "\($loc)\(refpart)", sparse: spargs} end
        elif $t == "url" then
          if has("headers") then {bad: "url+headers"}
          elif has("headersHelper") then {bad: "url+headersHelper"}
          elif (.url | okurl | not) then {bad: "invalid url"}
          else {human: "url:\(.url)", cli: .url, sparse: ""} end
        elif $t == "directory" or $t == "file" then
          if (.path | okpath | not) then {bad: "invalid path"} else {human: "\($t):\(.path)", cli: .path, sparse: ""} end
        else {bad: $t} end;
    ($p[0]) as $P | ($l[0]) as $L
    | (($P.enabledPlugins // {}) * ($L.enabledPlugins // {})) as $en
    | ((($P.extraKnownMarketplaces | if type == "object" then . else {} end) + ($L.extraKnownMarketplaces | if type == "object" then . else {} end))) as $ekm
    | ([$mk[0][] | objects | .name]) as $inst
    | ($list[0]) as $ls
    | $en | to_entries[] | select(.value == true) | .key as $id
    | select(($id | IN("superpowers@superpowers-marketplace", "superpowers@claude-plugins-official") | not) and (($id | split("@")[0]) != "orca-roles"))
    | (if ($id | okid | not) then [$id, "invalid-id"]
       else
         ($id | split("@")[1]) as $m
         | [$ls[] | objects | select(.id == $id and (.installPath | type) == "string" and .installPath != "" and (.scope == "user" or .scope == "managed" or ((.projectPath | type) == "string" and (.projectPath as $pp | $here | index($pp)))))] as $hits
         | if ($hits | map(select(.enabled == true)) | length) > 0 then [$id, "installed"]
           elif ($hits | length) > 0 then [$id, "disabled"]
           elif ($inst | index($m)) then [$id, "missing", "installed marketplace \($m)", "installed"]
           elif ($ekm | has($m)) then
             ((($ekm[$m] | objects | .source | objects) // {}) | resolve) as $r
             | if $r.bad then [$id, "unsupported-source", $r.bad] else [$id, "missing", $r.human, "declared", $r.cli, $r.sparse] end
           else [$id, "unknown-marketplace"] end
       end)
    | (. + ["", "", "", "", "", ""])[0:6] | map(dash) | @tsv' "$T/p.json" > "$T/plugins.tsv" 2>/dev/null \
    || { add_error "error could not compare the declared plugins with claude"; PLUGINS_OK=0; : > "$T/plugins.tsv"; }
}
# The line status prints for one plugins.tsv row
plugin_line() {  # plugin_line <id> <state> <field3>
  case "$2" in
    installed|disabled|invalid-id|unknown-marketplace) printf 'plugin\t%s\t%s\n' "$1" "$2";;
    missing|unsupported-source) printf 'plugin\t%s\t%s\t%s\n' "$1" "$2" "$3";;
  esac
}
compute_mcp() {  # prints the mcp lines
  local f="$FOLDER/.mcp.json" name cmd
  [ -f "$f" ] || return 0
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then add_error "error .mcp.json is not valid JSON"; return 0; fi
  while IFS=$'\t' read -r name cmd; do
    [ -n "$name" ] && [ -n "$cmd" ] || continue
    case "$cmd" in *'${'*) continue;; esac
    case "$cmd" in
      /*) [ -x "$cmd" ] && continue;;
      */*) [ -x "$FOLDER/$cmd" ] && continue;;   # relative to the project, not to where this runs
      *) command -v "$cmd" >/dev/null 2>&1 && continue;;
    esac
    printf 'mcp\t%s\tmissing-command\t%s\n' "$name" "$cmd"
  done < <(jq -r '.mcpServers | if type == "object" then to_entries[] | select((.value | type) == "object" and (.value.command | type) == "string") | [.key, .value.command] | @tsv else empty end' "$f")
}

compute_plugins
compute_mcp > "$T/mcp.out"   # not in a subshell: it may add an error line
MCP_LINES="$(cat "$T/mcp.out")"

case "$CMD" in
status)
  RC_OUT=0; OUT=""
  while IFS=$'\t' read -r id st f3 _; do
    [ -n "$id" ] || continue
    [ "$f3" != "-" ] || f3=""
    OUT="$OUT$(plugin_line "$id" "$st" "$f3")"$'\n'
    [ "$st" = installed ] || RC_OUT=2
  done < "$T/plugins.tsv"
  [ -z "$MCP_LINES" ] || { OUT="$OUT$MCP_LINES"$'\n'; RC_OUT=2; }
  OUT="$OUT$ERRORS"
  [ -z "$ERRORS" ] || RC_OUT=1
  printf '%s' "$OUT" | clean | grep . || true
  exit "$RC_OUT";;
install)
  if [ "$PLUGINS_OK" = 0 ]; then printf '%s' "$ERRORS" | clean | grep . >&2; exit 1; fi
  row="$(awk -F'\t' -v id="$ID" '$1 == id {print; exit}' "$T/plugins.tsv")"
  [ -n "$row" ] || { err "not declared by this project: $ID"; exit 2; }
  IFS=$'\t' read -r _ st f3 mk cli sparse <<<"$row"
  case "$st" in
    installed) printf 'installed %s\n' "$ID" | clean; exit 0;;
    disabled) err "disabled $ID: enable it with claude plugin enable $ID"; exit 3;;
    missing) ;;
    *) [ "$f3" != "-" ] || f3=""; plugin_line "$ID" "$st" "$f3" | clean >&2; exit 2;;
  esac
  if [ "$mk" != installed ]; then
    # --sparse takes a list: it goes last, after the source, or it would swallow the source
    SPARSE=(); if [ "$sparse" != "-" ]; then read -r -a SPA <<<"$sparse"; SPARSE=(--sparse "${SPA[@]}"); fi   # paths are validated: no spaces inside one
    bounded market claude plugin marketplace add --scope user "$cli" ${SPARSE[@]+"${SPARSE[@]}"}
    if [ "$TIMED" = 1 ]; then err "error claude timed out"; exit 1; fi
    if [ "$RC" != 0 ] && ! grep -qi 'already exists' "$T/market.out" "$T/market.err"; then
      row="$(first_line < "$T/market.err")"; [ -n "$row" ] || row="$(first_line < "$T/market.out")"; [ -n "$row" ] || row="claude plugin marketplace add exited $RC"
      err "error $row"; exit 1
    fi
  fi
  bounded install claude plugin install --scope user "$ID"
  if [ "$TIMED" = 1 ]; then err "error claude timed out"; exit 1; fi
  if [ "$RC" != 0 ]; then
    row="$(first_line < "$T/install.err")"; [ -n "$row" ] || row="$(first_line < "$T/install.out")"; [ -n "$row" ] || row="claude plugin install exited $RC"
    err "error $row"; exit 1
  fi
  printf 'installed %s\n' "$ID" | clean; exit 0;;
esac
