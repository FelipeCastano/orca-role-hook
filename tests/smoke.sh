#!/usr/bin/env bash
# orca-roles smoke tests: configuration, inheritance, per-project merge, update and the kit's scripts.
# Usage: tests/smoke.sh   (does not touch ~/.orca-roles)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export KIT="$TMP/kit"; mkdir -p "$KIT"
cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$KIT/"; chmod +x "$KIT"/bin/*.sh
. "$KIT/bin/lib.sh"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3], got [$2]"; FAIL=1; fi; }

# Syntax and JSON
for f in "$ROOT"/install.sh "$ROOT"/bin/*.sh "$ROOT"/tests/*.sh; do bash -n "$f"; done; echo "ok   bash syntax"
jq empty "$ROOT/config.default.json"; echo "ok   config.default.json is JSON"

# Every prompt follows the pattern
for p in "$ROOT"/prompts/*.md; do
  n="$(basename "$p" .md)"; [ "$n" = common-workers ] && continue
  for sec in '^# Role: ' '^## When you receive a task' '^## Limits' '^## Parameters' '^## Report' '^Now reply only'; do
    [ "$n" = planner ] && case "$sec" in '^## When you receive a task'|'^## Report'|'^Now reply only') continue;; esac
    grep -qE "$sec" "$p" || { echo "FAIL prompts/$n.md: missing section $sec"; FAIL=1; }
  done
done
grep -q '^## Code review method' "$ROOT/prompts/auditor.md" || { echo "FAIL auditor.md without its method"; FAIL=1; }
grep -q '^## Plan review method' "$ROOT/prompts/planner.md" || { echo "FAIL planner.md without its method"; FAIL=1; }
grep -q '^## Resuming a workspace after a restart' "$ROOT/prompts/planner.md" || { echo "FAIL planner.md without the resume section"; FAIL=1; }
grep -q 'reply to the user in the language they write to you in' "$ROOT/prompts/planner.md" || { echo "FAIL planner.md does not reply in the user's language"; FAIL=1; }
echo "ok   prompt pattern"

# Every role in the config has a prompt
for r in $(jq -r '.roles | keys_unsorted[]' "$KIT/config.default.json"); do
  [ -f "$(prompt_of "$KIT/config.default.json" "$r")" ] || { echo "FAIL role $r without a prompt"; FAIL=1; }
done; echo "ok   prompts of the default roles"

# Inheritance from defaults and the planner always enabled
cat > "$KIT/config.json" <<'J'
{ "settings": { "launchWaitSeconds": 3 },
  "defaults": { "agent": "claude", "permissionMode": "auto", "mcp": [], "allowedTools": ["Read"], "params": {} },
  "mcpServers": { "ctx": { "type": "http", "url": "http://x" } },
  "roles": {
    "planner": { "title": "Planner", "enabled": false, "mcp": "all" },
    "dev": { "title": "Dev", "model": "m-dev", "mcp": ["ctx"], "permissionMode": "acceptEdits" },
    "tester": { "title": "Tester", "enabled": false },
    "extra": { "title": "Extra", "agent": "custom", "command": "foo {model}", "prompt": "~/x/extra.md" }
  } }
J
C="$KIT/config.json"
check "planner always enabled even with enabled=false" "$(enabled_roles "$C" | tr '\n' ' ')" "planner dev extra "
check "rstr inherits from defaults" "$(rstr "$C" dev agent)" "claude"
check "rstr prefers the role" "$(rstr "$C" dev permissionMode)" "acceptEdits"
check "rcfg role mcp" "$(rcfg "$C" dev mcp)" '["ctx"]'
check "rcfg mcp all" "$(rcfg "$C" planner mcp)" '"all"'
check "rcfg empty when there is no value" "$(rcfg "$C" dev command)" ""
check "setting with default" "$(setting "$C" kickoffTimeoutSeconds 180)" "180"
check "setting defined" "$(setting "$C" launchWaitSeconds 15)" "3"
check "title_of" "$(title_of "$C" dev)" "Dev"
check "title_of without title" "$(title_of "$C" newone)" "newone"
check "var_of" "$(var_of visual-tester)" "VISUAL_TESTER"
check "prompt_of default" "$(prompt_of "$C" dev)" "$KIT/prompts/dev.md"
check "prompt_of with ~" "$(prompt_of "$C" extra)" "$HOME/x/extra.md"
check "regex_escape" "$(regex_escape 'feat/DEV-1.x+(y)')" 'feat/DEV-1\.x\+\(y\)'

# Merge with the project's .orca-roles.json (objects field by field, lists whole)
PROJ="$TMP/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
echo '{ "roles": { "dev": { "mcp": [] }, "tester": { "enabled": true } }, "settings": { "jiraHandoff": false } }' > "$PROJ/.orca-roles.json"
M="$(merged_config "$PROJ")"
check "merge: list replaced" "$(echo "$M" | jq -c '.roles.dev.mcp')" '[]'
check "merge: field kept" "$(echo "$M" | jq -r '.roles.dev.model')" 'm-dev'
check "merge: role re-enabled" "$(echo "$M" | jq -r '.roles.tester.enabled')" 'true'
check "merge: project setting" "$(echo "$M" | jq -r '.settings.jiraHandoff')" 'false'
check "merge: global setting kept" "$(echo "$M" | jq -r '.settings.launchWaitSeconds')" '3'
check "without .orca-roles.json returns the global one" "$(merged_config "$TMP" | jq -r '.roles.tester.enabled')" 'false'

# Update: new keys come in, the user's values and order are kept
U="$(upgrade_config "$KIT/config.default.json" "$C")"
check "upgrade: user's order first" "$(echo "$U" | jq -r '.roles | keys_unsorted | .[0:4] | join(" ")')" "planner dev tester extra"
check "upgrade: new roles at the end" "$(echo "$U" | jq -r '.roles | keys_unsorted | last')" "deployer"
check "upgrade: user's value kept" "$(echo "$U" | jq -r '.roles.dev.model')" "m-dev"
check "upgrade: user's enabled kept" "$(echo "$U" | jq -r '.roles.tester.enabled')" "false"
check "upgrade: new setting added" "$(echo "$U" | jq -r '.settings.kickoffTimeoutSeconds')" "180"
check "upgrade: mcpServers merged" "$(echo "$U" | jq -r '.mcpServers | keys | join(" ")')" "atlassian context7 ctx playwright"

# The Planner's startup message: handles, Jira, additional roles and resume mode
cat > "$KIT/config.json" <<'J'
{ "defaults": { "params": {} }, "mcpServers": {}, "roles": {
    "planner": { "title": "Planner" }, "dev": { "title": "Dev" },
    "sec": { "title": "Sec", "description": "reviews security" } } }
J
printf 'PLANNER=t1\nDEV=t2\nSEC=t3\n' > "$TMP/state.env"
M1="$(planner_msg "$KIT/config.json" "planner dev sec" "$TMP/state.env" "ABC-1" "https://x.atlassian.net/browse/ABC-1" 0)"
case "$M1" in *"Handles: Dev=t2, Sec=t3."*) echo "ok   planner_msg: handles";; *) echo "FAIL planner_msg handles: $M1"; FAIL=1;; esac
case "$M1" in *"Sec: reviews security"*) echo "ok   planner_msg: additional roles";; *) echo "FAIL planner_msg extra: $M1"; FAIL=1;; esac
case "$M1" in *"Jira ticket ABC-1 (https://x.atlassian.net/browse/ABC-1)"*) echo "ok   planner_msg: jira";; *) echo "FAIL planner_msg jira: $M1"; FAIL=1;; esac
case "$M1" in *"Start with the startup.") echo "ok   planner_msg: normal startup";; *) echo "FAIL planner_msg startup: $M1"; FAIL=1;; esac
M2="$(planner_msg "$KIT/config.json" "planner dev" "$TMP/state.env" "" "" 1)"
case "$M2" in *"RESUMED"*"Resuming a workspace after a restart"*"Start there.") echo "ok   planner_msg: resume mode";; *) echo "FAIL planner_msg resume: $M2"; FAIL=1;; esac
case "$M2" in *"Jira"*) echo "FAIL planner_msg without jira mentions Jira"; FAIL=1;; *) echo "ok   planner_msg: without jira";; esac
case "$M2" in *"Sec"*) echo "FAIL planner_msg includes an inactive role"; FAIL=1;; *) echo "ok   planner_msg: only active roles";; esac
case "$M2" in *"Always reply to the user in"*) echo "FAIL planner_msg sets a language without settings.language"; FAIL=1;; *) echo "ok   planner_msg: language auto by default";; esac
jq '.settings.language = "Spanish"' "$KIT/config.json" > "$TMP/lang.json"
case "$(planner_msg "$TMP/lang.json" "planner dev" "$TMP/state.env" "" "" 0)" in *"Always reply to the user in Spanish, whatever language they write in."*) echo "ok   planner_msg: settings.language";; *) echo "FAIL planner_msg language"; FAIL=1;; esac
check "default config: language auto" "$(jq -r '.settings.language' "$ROOT/config.default.json")" "auto"

# Worker cleanup: worker_msg, clear_command and clean.sh with a fake 'orca'
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1 }, "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": {
    "planner": { "title": "Planner" },
    "dev": { "title": "Dev", "params": { "a": 1 } },
    "cx": { "title": "Codex", "agent": "codex" },
    "cu": { "title": "Custom", "agent": "custom", "command": "x" },
    "cc": { "title": "Custom2", "agent": "custom", "command": "x", "clearCommand": "/reset" } } }
J
C="$KIT/config.json"
check "worker_msg with parameters" "$(worker_msg "$C" dev)" "Read $KIT/prompts/common-workers.md and $KIT/prompts/dev.md and adopt that role from now on. Follow its instructions to the letter. Configuration parameters: a=1."
case "$(worker_msg "$C" cx)" in *"parameters"*) echo "FAIL worker_msg without params mentions parameters"; FAIL=1;; *) echo "ok   worker_msg without parameters";; esac
check "clear_command claude" "$(clear_command "$C" dev)" "/clear"
check "clear_command codex" "$(clear_command "$C" cx)" "/new"
check "clear_command custom undefined" "$(clear_command "$C" cu)" ""
check "clear_command explicit" "$(clear_command "$C" cc)" "/reset"
printf 'PLANNER=t1\nDEV=t2\nCX=t3\nCU=t4\n' > "$TMP/state.env"
mkdir -p "$TMP/fakebin" "$TMP/home"; ln -sfn "$KIT" "$TMP/home/.orca-roles"   # fake HOME: ~/.orca-roles → test kit
LOGF="$TMP/orca.log"; : > "$LOGF"
cat > "$TMP/fakebin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$LOGF"
case "\$*" in *"--terminal t3 "*) [ "\$2" = show ] && exit 1;; esac
exit 0
EOS
chmod +x "$TMP/fakebin/orca"
run_clean() { (cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/clean.sh" "$@" 2>&1); }
try() { if OUT="$("$@")"; then RC=0; else RC=$?; fi; }   # captures output and exit code without tripping set -e
try run_clean dev
check "clean.sh dev: result" "$RC:$OUT" "0:Dev: context cleaned (/clear) and role resent."
check "clean.sh dev: sends /clear, waits and resends the role" "$(grep -c -E 'terminal send --terminal t2 --text /clear --enter|terminal wait --terminal t2 --for tui-idle|terminal send --terminal t2 --text Read .*dev.md.*a=1\. --enter' "$LOGF")" "3"
try run_clean Codex; check "clean.sh by title and dead tab" "$RC:$OUT" "1:Codex: its tab (t3) does not respond."
check "clean.sh by handle" "$(run_clean t2)" "Dev: context cleaned (/clear) and role resent."
try run_clean planner; check "clean.sh refuses the planner" "$RC:$OUT" "1:Planner: the Planner does not clean itself."
try run_clean cu; check "clean.sh custom without clearCommand" "$RC" "1"; case "$OUT" in *clearCommand*) echo "ok   clean.sh explains clearCommand";; *) echo "FAIL clean.sh: $OUT"; FAIL=1;; esac
try run_clean nobody; check "clean.sh unknown role" "$RC" "1"
: > "$LOGF"; try run_clean --all; check "clean.sh --all: dead tab reported" "$RC" "1"; case "$OUT" in *"Codex: its tab (t3) does not respond."*) echo "ok   clean.sh --all: dead tab message";; *) echo "FAIL clean.sh --all: $OUT"; FAIL=1;; esac
check "clean.sh --all excludes the planner" "$(grep -c 'terminal show --terminal t1' "$LOGF" || true)" "0"
check "clean.sh --all goes through the workers" "$(grep -c 'terminal show' "$LOGF")" "3"
check "clean.sh --msg" "$(run_clean --msg dev | sed "s#$TMP/home/.orca-roles#$KIT#g")" "$(worker_msg "$C" dev)"
rm -f "$TMP/fakebin/orca"
M3="$(planner_msg "$C" "planner dev" "$TMP/state.env" "" "" 0)"
case "$M3" in *"propose to the user cleaning the workers' context"*) echo "ok   planner_msg: cleanup when closing a step";; *) echo "FAIL planner_msg cleanup: $M3"; FAIL=1;; esac

# MCP for any agent: mcpServers file, Codex overrides, {mcp} placeholder in custom, --mcp-config in claude
cat > "$KIT/config.json" <<'J'
{ "defaults": { "mcp": [] }, "mcpServers": {
    "ctx": { "type": "http", "url": "http://ctx" },
    "pw": { "command": "npx", "args": ["-y", "@playwright/mcp@latest"], "env": { "A": "1" } } },
  "roles": {
    "cl": { "agent": "claude", "mcp": ["ctx"] },
    "cla": { "agent": "claude", "mcp": "all" },
    "cx": { "agent": "codex", "mcp": ["ctx", "pw", "nope"] },
    "cu": { "agent": "custom", "command": "run --mcp {mcp}", "mcp": ["pw"] },
    "cua": { "agent": "custom", "command": "run --mcp {mcp}", "mcp": "all" } } }
J
C="$KIT/config.json"
check "mcp_file filters by name" "$(mcp_file "$C" cx | jq -c '.mcpServers | keys')" '["ctx","pw"]'
check "mcp_file empty" "$(mcp_file "$C" cua | jq -c .)" '{"mcpServers":{}}'
mcp_file "$C" cx > "$TMP/mcp.json"
check "codex overrides" "$(codex_mcp_overrides "$TMP/mcp.json" | tr '\n' '|')" 'mcp_servers.ctx.url="http://ctx"|mcp_servers.pw.command="npx"|mcp_servers.pw.args=["-y","@playwright/mcp@latest"]|mcp_servers.pw.env={A = "1"}|'
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$TMP/fakebin/codex"; chmod +x "$TMP/fakebin/codex"
cp "$TMP/fakebin/codex" "$TMP/fakebin/claude"
printf '#!/bin/sh\n[ "$1" = -lc ] && { echo "$2"; exit 0; }\nexec /bin/bash "$@"\n' > "$TMP/fakebin/bash"; chmod +x "$TMP/fakebin/bash"   # bash -lc → prints the command
run_agent() { (cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/agent.sh" "$@" 2>&1); }
OUT="$(run_agent cx | tr '\n' ' ')"
case "$OUT" in *'-c mcp_servers.ctx.url="http://ctx" -c mcp_servers.pw.command="npx" -c mcp_servers.pw.args=["-y","@playwright/mcp@latest"] -c mcp_servers.pw.env={A = "1"} '*) echo "ok   agent.sh codex: -c per server";; *) echo "FAIL agent.sh codex: $OUT"; FAIL=1;; esac
OUT="$(run_agent cl | tr '\n' ' ')"
case "$OUT" in *"--strict-mcp-config --mcp-config "*) echo "ok   agent.sh claude: --mcp-config";; *) echo "FAIL agent.sh claude: $OUT"; FAIL=1;; esac
F="$(run_agent cl | grep -A1 -- '--mcp-config' | tail -1)"; check "agent.sh claude: file contents" "$(jq -c '.mcpServers | keys' "$F")" '["ctx"]'
OUT="$(run_agent cla | tr '\n' ' ')"
case "$OUT" in *"--mcp-config"*) echo "FAIL agent.sh claude all passes mcp-config"; FAIL=1;; *) echo "ok   agent.sh claude: all does not restrict";; esac
OUT="$(run_agent cu)"; F="${OUT#run --mcp }"
check "agent.sh custom: {mcp} points to a file with the servers" "$(jq -c '.mcpServers | keys' "$F" 2>/dev/null)" '["pw"]'
check "agent.sh custom: {mcp} empty with all" "$(run_agent cua)" "run --mcp "
rm -f "$TMP/fakebin/codex" "$TMP/fakebin/claude"

# mcpServers placeholders, project name and browser state
cat > "$KIT/config.json" <<'J'
{ "defaults": { "mcp": [] }, "mcpServers": {
    "pw": { "command": "npx", "args": ["-y", "@playwright/mcp@latest", "--headless", "--storage-state", "{browserState}", "--output-dir", "{worktree}/{evidenceDir}"], "env": { "P": "{project}", "K": "{kit}" } },
    "h": { "type": "http", "url": "http://{home}/x" } },
  "roles": { "vt": { "agent": "custom", "command": "run {mcp}", "mcp": ["pw", "h"], "params": { "evidenceDir": "ev" } },
             "other": { "agent": "custom", "command": "run {mcp}", "mcp": ["pw"] } } }
J
C="$KIT/config.json"
check "project_name in a worktree" "$(project_name "$PROJ")" "proj"
mkdir -p "$TMP/plain"; check "project_name without git" "$(project_name "$TMP/plain")" "plain"
( role_context "$C" vt "$PROJ"
  check "role_context: worktree" "$ORCA_ROLES_WORKTREE" "$(cd "$PROJ" && pwd)"
  check "role_context: the role's evidenceDir" "$ORCA_ROLES_EVIDENCE_DIR" "ev"
  check "role_context: browser state per project" "$ORCA_ROLES_BROWSER_STATE" "$KIT/browser/proj.json"
  A="$(mcp_file "$C" vt | jq -c '.mcpServers.pw.args')"
  check "mcp_file expands placeholders in args" "$A" "[\"-y\",\"@playwright/mcp@latest\",\"--headless\",\"--storage-state\",\"$KIT/browser/proj.json\",\"--output-dir\",\"$(cd "$PROJ" && pwd)/ev\"]"
  check "mcp_file expands in env and url" "$(mcp_file "$C" vt | jq -r '.mcpServers.pw.env.P + " " + .mcpServers.pw.env.K + " " + .mcpServers.h.url')" "proj $KIT http://$HOME/x"
  [ "$FAIL" = 0 ] ) || FAIL=1
( role_context "$C" other "$PROJ"; check "role_context: default evidenceDir" "$ORCA_ROLES_EVIDENCE_DIR" "qa-evidence"; [ "$FAIL" = 0 ] ) || FAIL=1
OUT="$(cd "$PROJ" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/agent.sh" vt 2>&1)"; F="${OUT#run }"
check "agent.sh creates the empty browser state" "$(cat "$TMP/home/.orca-roles/browser/proj.json" 2>/dev/null)" '{"cookies":[],"origins":[]}'
check "agent.sh: MCP file with expanded placeholders" "$(jq -r '.mcpServers.pw.args[4]' "$F" 2>/dev/null)" "$TMP/home/.orca-roles/browser/proj.json"
echo '{"cookies":[{"n":1}],"origins":[]}' > "$KIT/browser/proj.json"
( role_context "$C" vt "$PROJ"; ensure_browser_state "$ORCA_ROLES_BROWSER_STATE"; check "ensure_browser_state does not overwrite an existing session" "$(jq -c '.cookies | length' "$KIT/browser/proj.json")" "1"; [ "$FAIL" = 0 ] ) || FAIL=1
grep -q -- '--headless' "$ROOT/config.default.json" && grep -q '{browserState}' "$ROOT/config.default.json" && grep -q '{worktree}/{evidenceDir}' "$ROOT/config.default.json" && echo "ok   config.default: headless playwright with session and evidence" || { echo "FAIL config.default playwright"; FAIL=1; }
for sec in '^## Your browser' 'browser-login.sh' 'browser_evaluate'; do grep -q "$sec" "$ROOT/prompts/visual-tester.md" || { echo "FAIL visual-tester.md without $sec"; FAIL=1; }; done
grep -q 'browser-login.sh' "$ROOT/prompts/planner.md" || { echo "FAIL planner.md without browser-login"; FAIL=1; }
grep -q 'orca-<service>.pid' "$ROOT/prompts/deployer.md" || { echo "FAIL deployer.md without services"; FAIL=1; }
echo "ok   visual test prompts"

# agent.sh custom: placeholders and extraArgs (bash is replaced by an echo)
cat > "$KIT/config.json" <<J
{ "defaults": {}, "mcpServers": {}, "roles": { "x": { "agent": "custom", "command": "run --m {model} --p {prompts} --f {prompt}", "model": "a b", "extraArgs": ["--k", "v w"] } } }
J
printf '#!/bin/sh\n[ "$1" = -lc ] && { echo "$2"; exit 0; }\nexec /bin/bash "$@"\n' > "$TMP/fakebin/bash"; chmod +x "$TMP/fakebin/bash"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$KIT/bin/agent.sh" x)"
check "custom: command with placeholders and extraArgs" "$OUT" "run --m a\\ b --p $TMP/home/.orca-roles/prompts --f $TMP/home/.orca-roles/prompts/x.md --k v\\ w"

# Jira key: Orca's (linkedWorkItem) wins; without a link, only from the branch and in uppercase at the start of a segment
check "jira: Orca's jiraIdentifier" "$(jira_key feature/other-thing devgd-220 "")" "DEVGD-220"
check "jira: URL if there is no identifier" "$(jira_key feature/ABC-1 "" "https://jira.company.com/browse/devgd-7")" "DEVGD-7"
check "jira: branch with key" "$(jira_key DEVGD-220-new-api "" "")" "DEVGD-220"
check "jira: key after prefix" "$(jira_key feature/DEVGD-220 "" "")" "DEVGD-220"
check "jira: fix-123 is not a ticket" "$(jira_key feature/fix-123 "" "")" ""
check "jira: release-1.4 is not a ticket" "$(jira_key release-1.4 "" "")" ""
check "jira: branch without key" "$(jira_key main "" "")" ""
JSON='{"worktree":{"branch":"x","linkedWorkItem":{"provider":"jira","type":"issue","number":0,"title":"t","url":"https://jira.company.com/browse/DEVGD-9","jiraIdentifier":"DEVGD-9"}}}'
check "jira: jiraIdentifier in orca worktree show" "$(printf '%s' "$JSON" | jq -r '[.. | objects | select(.provider? == "jira") | .jiraIdentifier // empty] | first // empty')" "DEVGD-9"

# Title of the composer's extra session: exact branch or starts with the key
RE="$(composer_title_regex DEVGD-220 api)"
t_match() { jq -nr --arg re "$RE" --arg t "$1" '$t | test($re; "i")'; }
check "composer: exact key" "$(t_match DEVGD-220)" "true"
check "composer: key with summary" "$(t_match 'devgd-220: new api')" "true"
check "composer: another, longer key" "$(t_match DEVGD-2201)" "false"
check "composer: exact branch" "$(t_match api)" "true"
check "composer: branch as substring" "$(t_match 'api tests')" "false"
check "composer: branch with regex characters" "$(composer_title_regex "" feat/a.b)" '^(feat/a\.b)$'
check "composer: neither key nor branch" "$(composer_title_regex "" "")" ""

# An uncommitted .orca-roles.json in the main checkout also applies to its worktrees
MAIN="$TMP/main"; mkdir -p "$MAIN"; git -C "$MAIN" init -q
git -C "$MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$TMP/wt" -b wt-branch 2>/dev/null
echo '{ "settings": { "jiraHandoff": false } }' > "$MAIN/.orca-roles.json"
check "project config from the main checkout" "$(merged_config "$TMP/wt" | jq -r '.settings.jiraHandoff')" "false"
echo '{ "settings": { "jiraHandoff": true } }' > "$TMP/wt/.orca-roles.json"
check "project config: the worktree's wins" "$(merged_config "$TMP/wt" | jq -r '.settings.jiraHandoff')" "true"

# MCP file in the worktree's git dir (temporary files do not pile up)
check "agent.sh: MCP file in the git dir" "$F" "$(cd "$PROJ/.git" && pwd)/orca-roles-mcp-vt.json"

# Empty lists (macOS bash 3.2 fails with an empty "${A[@]}" and set -u)
cat > "$KIT/config.json" <<'J'
{ "defaults": {}, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "cx": { "agent": "codex", "mcp": "all" } } }
J
printf '#!/bin/sh\necho "codex:$#"\n' > "$TMP/fakebin/codex"; chmod +x "$TMP/fakebin/codex"
check "agent.sh codex without arguments" "$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$KIT/bin/agent.sh" cx 2>&1)" "codex:0"
printf 'PLANNER=t1\n' > "$TMP/state.env"
check "clean.sh --all without workers" "$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$KIT/config.json" "$KIT/bin/clean.sh" --all 2>&1)" "There are no workers to clean in this workspace."

# Orca CLI under another name (WSL: ORCA_CLI_COMMAND=orca-ide): 'orca' wrapper in $KIT/shim
mkdir -p "$TMP/cli"; printf '#!/bin/sh\necho "orca-ide:$*"\n' > "$TMP/cli/orca-ide"; chmod +x "$TMP/cli/orca-ide"
check "shim: 'orca' calls ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide bash -c '. "$KIT/bin/lib.sh"; orca terminal list')" "orca-ide:terminal list"
rm -f "$KIT/shim/orca"
check "shim: not created without ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND='' bash -c '. "$KIT/bin/lib.sh"; command -v orca || echo none')" "none"
check "shim: not created if 'orca' already exists" "$(PATH="$TMP/fakebin:$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide bash -c 'printf "#!/bin/sh\n" > "$0/orca"; chmod +x "$0/orca"; . "$KIT/bin/lib.sh"; command -v orca' "$TMP/fakebin")" "$TMP/fakebin/orca"
rm -f "$TMP/fakebin/orca"

# roles-yaml: local orca.yaml, ignored and listed in .worktreeinclude, nothing to commit
Y="$TMP/ymain"; mkdir -p "$Y"; git -C "$Y" init -q; git -C "$Y" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$Y" worktree add -q "$TMP/ywt" -b ybranch 2>/dev/null
yaml() { (cd "$1" && shift && "$ROOT/bin/orca-yaml.sh" "$@" 2>&1); }
try yaml "$TMP/ywt"; check "roles-yaml: succeeds from a worktree" "$RC" "0"
check "roles-yaml: orca.yaml in the main checkout" "$(grep -c 'orca-roles/bin/launch.sh' "$Y/orca.yaml")" "1"
check "roles-yaml: listed in .worktreeinclude" "$(grep -cx orca.yaml "$Y/.worktreeinclude")" "1"
check "roles-yaml: ignored by git" "$(git -C "$Y" check-ignore orca.yaml .worktreeinclude | tr '\n' ' ')" "orca.yaml .worktreeinclude "
check "roles-yaml: nothing to commit" "$(git -C "$Y" status --porcelain)" ""
BEFORE="$(cat "$Y/orca.yaml" "$Y/.worktreeinclude" "$Y/.git/info/exclude")"
yaml "$TMP/ywt" >/dev/null; check "roles-yaml: idempotent" "$(cat "$Y/orca.yaml" "$Y/.worktreeinclude" "$Y/.git/info/exclude")" "$BEFORE"
check "roles-yaml: no repeated lines in exclude" "$(grep -cx orca.yaml "$Y/.git/info/exclude")" "1"
try yaml "$Y" --remove; check "roles-yaml --remove" "$RC:$(ls -A "$Y" | tr '\n' ' '):$(grep -cx 'orca.yaml\|.worktreeinclude' "$Y/.git/info/exclude" || true)" "0:.git :0"
printf 'scripts:\n  setup: npm i\n' > "$Y/orca.yaml"
try yaml "$Y"; check "roles-yaml: leaves someone else's orca.yaml alone" "$RC:$(cat "$Y/orca.yaml" | tr '\n' ' ')" "1:scripts:   setup: npm i "
git -C "$Y" add orca.yaml; git -C "$Y" -c user.name=t -c user.email=t@t commit -q -m yaml
try yaml "$Y"; check "roles-yaml: leaves a committed orca.yaml alone" "$RC" "1"; case "$OUT" in *committed*) echo "ok   roles-yaml explains the committed orca.yaml";; *) echo "FAIL roles-yaml: $OUT"; FAIL=1;; esac

# launch.sh exceptions (the project's setup script): --only, --enable, --disable, --set, saved per worktree
check "overrides: lists and typed --set" "$(overrides_from_args --only planner,dev --disable 'x, y' --set roles.dev.model=m1 --set=settings.jiraHandoff=false --set roles.t.params.n=5)" \
  '{"only":["planner","dev"],"enable":[],"disable":["x","y"],"set":[{"path":["roles","dev","model"],"value":"m1"},{"path":["settings","jiraHandoff"],"value":false},{"path":["roles","t","params","n"],"value":5}]}'
try overrides_from_args --nope 2>/dev/null; check "overrides: unknown option" "$RC" "1"
try overrides_from_args --set novalue 2>/dev/null; check "overrides: --set without =" "$RC" "1"
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev", "model": "m-dev" },
             "tester": { "title": "Tester", "enabled": false }, "deployer": { "title": "Deployer" } } }
J
overrides_from_args --only dev --enable tester --set roles.dev.model=m2 > "$TMP/ovr.json"
check "apply_overrides: --only keeps planner and dev, --enable adds tester" "$(apply_overrides "$KIT/config.json" "$TMP/ovr.json" > "$TMP/c.json"; enabled_roles "$TMP/c.json" | tr '\n' ' ')" "planner dev tester "
check "apply_overrides: --set" "$(jq -r '.roles.dev.model' "$TMP/c.json")" "m2"
overrides_from_args --disable planner,nobody > "$TMP/ovr.json"
check "check_overrides: unknown role" "$(check_overrides "$KIT/config.json" "$TMP/ovr.json" | grep -c '^ERROR: unknown roles: nobody\. Available: ')" "1"
check "check_overrides: the planner cannot be disabled" "$(check_overrides "$KIT/config.json" "$TMP/ovr.json" | grep -c '^ERROR: the planner cannot be disabled$')" "1"
# launch.sh end to end with a fake 'orca' (each tab is called h-<title>; none is alive when relaunching)
L="$TMP/lproj"; mkdir -p "$L" "$TMP/lbin"; git -C "$L" init -q
cat > "$TMP/lbin/orca" <<'EOS'
#!/bin/sh
case "$1 $2" in
  "terminal create") while [ $# -gt 0 ]; do [ "$1" = --title ] && t="$2"; shift; done; echo "{\"handle\":\"h-$t\"}";;
  "terminal show") exit 1;;
esac
exit 0
EOS
chmod +x "$TMP/lbin/orca"
launch() { (cd "$L" && HOME="$TMP/home" PATH="$TMP/lbin:$PATH" "$TMP/home/.orca-roles/bin/launch.sh" "$@" 2>&1); }
handles() { cut -d= -f1 "$L/.git/orca-roles.env" | tr '\n' ' '; }
try launch --disable deployer --set roles.dev.model=m3; check "launch: --disable" "$RC:$(handles)" "0:PLANNER DEV "
check "launch: --set in the effective config" "$(jq -r '.roles.dev.model' "$L/.git/orca-roles.config.json")" "m3"
try launch; check "launch: resumes with the saved exceptions" "$RC:$(handles)" "0:PLANNER DEV "
case "$OUT" in *"saved exceptions"*) echo "ok   launch: reports the saved exceptions";; *) echo "FAIL launch saved: $OUT"; FAIL=1;; esac
try launch --reset; check "launch: --reset goes back to the configuration" "$RC:$(handles)" "0:PLANNER DEV DEPLOYER "
try launch --only dev; check "launch: --only" "$RC:$(handles)" "0:PLANNER DEV "
try launch --enable nobody; check "launch: unknown role fails" "$RC" "1"
check "launch: an error does not overwrite the saved exceptions" "$(jq -c .only "$L/.git/orca-roles.overrides.json")" '["dev"]'
sleep 1   # lets the background kickoffs finish before the temporary directory is deleted

# The Planner's skill: plugin, new-role --from-json, per-worktree instructions and plugin loading
jq -e '.name == "orca-roles"' "$ROOT/plugin/.claude-plugin/plugin.json" >/dev/null && echo "ok   plugin.json valid" || { echo "FAIL plugin.json"; FAIL=1; }
check "skill: name in the frontmatter" "$(sed -n 2p "$ROOT/plugin/skills/team/SKILL.md")" "name: team"
grep -q '^## Managing the kit and the team' "$ROOT/prompts/planner.md" && echo "ok   planner.md links the skill" || { echo "FAIL planner.md without the skill"; FAIL=1; }
check "default config: the planner's plugin" "$(jq -c '.roles.planner.pluginDirs' "$ROOT/config.default.json")" '["{kit}/plugin"]'
cat > "$KIT/config.json" <<'J'
{ "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" }, "tester": { "title": "Tester" } } }
J
newrole() { (cd "$TMP" && HOME="$TMP/home" "$TMP/home/.orca-roles/bin/new-role.sh" --from-json "$1" 2>&1); }
printf '%s' '{"id":"sec-review","description":"reviews security","model":"m-sec","params":{"maxFindings":20},"after":"dev","prompt":"# Role: SEC\n\n## Report\nx\n"}' > "$TMP/role.json"
try newrole "$TMP/role.json"; check "from-json: creates the role" "$RC" "0"
check "from-json: position after dev" "$(jq -r '.roles | keys_unsorted | join(" ")' "$KIT/config.json")" "planner dev sec-review tester"
check "from-json: fields and default title" "$(jq -c '.roles["sec-review"] | {title, description, enabled, agent, model, params}' "$KIT/config.json")" '{"title":"Sec-Review","description":"reviews security","enabled":true,"agent":"claude","model":"m-sec","params":{"maxFindings":20}}'
check "from-json: prompt in roles/" "$(head -1 "$KIT/roles/sec-review.md"):$(jq -r '.roles["sec-review"].prompt' "$KIT/config.json")" "# Role: SEC:$TMP/home/.orca-roles/roles/sec-review.md"
[ -f "$KIT/config.json.bak" ] && echo "ok   from-json: .bak copy" || { echo "FAIL from-json without .bak"; FAIL=1; }
try newrole "$TMP/role.json"; check "from-json: does not overwrite without overwrite" "$RC" "1"
jq '. + {overwrite: true, model: "m2"}' "$TMP/role.json" > "$TMP/role2.json"
try newrole "$TMP/role2.json"; check "from-json: overwrite" "$RC:$(jq -r '.roles["sec-review"].model' "$KIT/config.json")" "0:m2"
printf '%s' '{"id":"Bad Id","description":"x","prompt":"p"}' > "$TMP/role3.json"; try newrole "$TMP/role3.json"; check "from-json: invalid id" "$RC" "1"
printf '%s' '{"id":"no-desc","prompt":"p"}' > "$TMP/role3.json"; try newrole "$TMP/role3.json"; check "from-json: without description" "$RC" "1"
printf '%s' '{"id":"planner","description":"x","prompt":"p"}' > "$TMP/role3.json"; try newrole "$TMP/role3.json"; check "from-json: planner reserved" "$RC" "1"
# A role's instructions for this worktree only, inside its role message
N="$TMP/nproj"; mkdir -p "$N"; git -C "$N" init -q; mkdir -p "$N/.git/orca-roles.notes"
printf 'Use pnpm.\nDo not touch the legacy folder.\n' > "$N/.git/orca-roles.notes/dev.md"
case "$(cd "$N" && worker_msg "$KIT/config.json" dev)" in *"Additional instructions for this worktree, which take precedence over your prompt if they conflict: Use pnpm. Do not touch the legacy folder." ) echo "ok   worker_msg includes the worktree's instructions";; *) echo "FAIL worker_msg notes: $(cd "$N" && worker_msg "$KIT/config.json" dev)"; FAIL=1;; esac
case "$(cd "$N" && worker_msg "$KIT/config.json" tester)" in *"Additional instructions"*) echo "FAIL worker_msg: notes in a role without notes"; FAIL=1;; *) echo "ok   worker_msg without notes adds nothing";; esac
# agent.sh passes the plugin and the extra folders with ~ and {kit} expanded
cat > "$KIT/config.json" <<'J'
{ "defaults": { "mcp": [] }, "mcpServers": {}, "roles": { "planner": { "agent": "claude", "mcp": "all", "extraDirs": ["{kit}", "~/x"], "pluginDirs": ["{kit}/plugin"] } } }
J
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$TMP/fakebin/claude"; chmod +x "$TMP/fakebin/claude"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" planner | tr '\n' ' ')"
case "$OUT" in *"--add-dir $TMP/home/.orca-roles --add-dir $TMP/home/x --plugin-dir $TMP/home/.orca-roles/plugin "*) echo "ok   agent.sh: --plugin-dir and --add-dir expanded";; *) echo "FAIL agent.sh plugin: $OUT"; FAIL=1;; esac
rm -f "$TMP/fakebin/claude"

[ "$FAIL" = 0 ] && echo "ALL OK" || { echo "FAILURES"; exit 1; }
