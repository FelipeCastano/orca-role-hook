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
grep -q 'No heartbeats' "$ROOT/prompts/common-workers.md" || { echo "FAIL common-workers.md: falta la regla de no enviar heartbeats"; FAIL=1; }
grep -q 'lastOutputAt' "$ROOT/prompts/planner.md" || { echo "FAIL planner.md: la detección de workers silenciosos debe usar lastOutputAt"; FAIL=1; }
grep -q 'last_heartbeat_at' "$ROOT/prompts/planner.md" && { echo "FAIL planner.md: aún depende de last_heartbeat_at"; FAIL=1; }
echo "ok   heartbeats: workers no laten, planner vigila por lastOutputAt"
for p in common-workers planner; do grep -q 'No names of people anywhere you write' "$ROOT/prompts/$p.md" || { echo "FAIL $p.md: missing the no-names-of-people rule"; FAIL=1; }; done
grep -q 'No new code comments unless the repo' "$ROOT/prompts/common-workers.md" || { echo "FAIL common-workers.md: missing the comments rule"; FAIL=1; }
grep -q 'Names and stray comments' "$ROOT/prompts/auditor.md" || { echo "FAIL auditor.md: missing the names/comments finding"; FAIL=1; }
echo "ok   rules: no names of people, comments only if the repo uses them, auditor finding"
for p in common-workers planner; do
  r=$(grep 'No names of people anywhere you write' "$ROOT/prompts/$p.md" || true)
  for k in 'Handles (`@user`) and email addresses count as names' '"the repo owner"' 'not `<name>_test_user`' 'not "as <name> asked"' 'Names of products, libraries, companies and services'; do
    printf '%s' "$r" | grep -qF -- "$k" || { echo "FAIL $p.md: the no-names rule lost: $k"; FAIL=1; }
  done
done
grep 'No new code comments unless the repo' "$ROOT/prompts/common-workers.md" | grep -qF 'Never delete existing comments' || { echo "FAIL common-workers.md: the comments rule lost 'never delete existing comments'"; FAIL=1; }
grep 'No new code comments unless the repo' "$ROOT/prompts/common-workers.md" | grep -qF 'narrates the change' || { echo "FAIL common-workers.md: the comments rule lost 'never narrate the change'"; FAIL=1; }
a=$(grep 'Names and stray comments' "$ROOT/prompts/auditor.md" || true)
for k in 'handle or an email address' '**low** severity' 'Owner: **Dev** for code, **Tester** for tests'; do
  printf '%s' "$a" | grep -qF -- "$k" || { echo "FAIL auditor.md: the names/comments finding lost: $k"; FAIL=1; }
done
# the examples use placeholders, not real people
grep -rEq '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z.]{2,}' "$ROOT/prompts/" && { echo "FAIL prompts contain an email address"; FAIL=1; }
for p in common-workers planner; do
  at=$(grep -n 'never carry attribution to an AI' "$ROOT/prompts/$p.md" | head -1 | cut -d: -f1 || true)
  nn=$(grep -n 'No names of people anywhere you write' "$ROOT/prompts/$p.md" | head -1 | cut -d: -f1 || true)
  [ -n "$at" ] && [ -n "$nn" ] && [ "$nn" -eq $((at + 1)) ] || { echo "FAIL $p.md: the no-names rule must sit right after the AI-attribution rule"; FAIL=1; }
  grep -qF "Merge pull request #N from <handle>/<branch>" "$ROOT/prompts/$p.md" || { echo "FAIL $p.md: the commit rule lost the GitHub merge-subject warning"; FAIL=1; }
done
c=$(grep 'No new code comments unless the repo' "$ROOT/prompts/common-workers.md" || true)
for k in 'comment density' 'CLAUDE.md' 'CONTRIBUTING' 'linter' 'none at all in a repo whose code carries none'; do
  printf '%s' "$c" | grep -qF -- "$k" || { echo "FAIL common-workers.md: the comments rule lost: $k"; FAIL=1; }
done
pass=$(awk '/^### Passes/{f=1;next} /^### /{f=0} f' "$ROOT/prompts/auditor.md" | grep 'Names and stray comments' || true)
printf '%s' "$pass" | grep -qF 'Jira' || { echo "FAIL auditor.md: the names/comments pass must live under '### Passes' and cover Jira"; FAIL=1; }
echo "ok   rules: key content pinned, examples use placeholders"

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
check "var_of" "$(var_of e2e-tester)" "E2E_TESTER"
# Renamed role: visual-tester → e2e-tester, keeping the user's settings and position
printf '{"roles":{"dev":{},"visual-tester":{"title":"Visual-Tester","enabled":false},"deployer":{}}}' > "$TMP/legacy.json"
check "upgrade_config renames visual-tester" "$(upgrade_config "$ROOT/config.default.json" "$TMP/legacy.json" | jq -c '[(.roles | keys_unsorted | .[0:3]), .roles["e2e-tester"].title, .roles["e2e-tester"].enabled, (.roles | has("visual-tester"))]')" '[["dev","e2e-tester","deployer"],"E2E-Tester",false,false]'
check "overrides accept the old id" "$(overrides_from_args --disable visual-tester --set roles.visual-tester.model=m | jq -c '[.disable, .set[0].path]')" '[["e2e-tester"],["roles","e2e-tester","model"]]'
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
check "worker_msg with parameters" "$(cd "$TMP" && worker_msg "$C" dev)" "Read $KIT/prompts/common-workers.md and $KIT/prompts/dev.md and adopt that role from now on. Follow its instructions to the letter. Configuration parameters: a=1, scratchDir=$(cd "$TMP" && scratch_dir dev)."
case "$(cd "$TMP" && worker_msg "$C" cx)" in *"a=1"*) echo "FAIL worker_msg without params shows another role's"; FAIL=1;; *"Configuration parameters: scratchDir=$KIT/tmp/"*) echo "ok   worker_msg without parameters (only scratchDir)";; *) echo "FAIL worker_msg without params: $(cd "$TMP" && worker_msg "$C" cx)"; FAIL=1;; esac
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
check "clean.sh dev: sends /clear, waits and resends the role" "$(grep -c -E 'terminal send --terminal t2 --text /clear --enter|terminal wait --terminal t2 --for tui-idle|terminal send --terminal t2 --text Read .*dev.md.*a=1, scratchDir=.*\. --enter' "$LOGF")" "3"
try run_clean Codex; check "clean.sh by title and dead tab" "$RC:$OUT" "1:Codex: its tab (t3) does not respond."
check "clean.sh by handle" "$(run_clean t2)" "Dev: context cleaned (/clear) and role resent."
try run_clean planner; check "clean.sh refuses the planner" "$RC:$OUT" "1:Planner: the Planner does not clean itself."
try run_clean cu; check "clean.sh custom without clearCommand" "$RC" "1"; case "$OUT" in *clearCommand*) echo "ok   clean.sh explains clearCommand";; *) echo "FAIL clean.sh: $OUT"; FAIL=1;; esac
try run_clean nobody; check "clean.sh unknown role" "$RC" "1"
: > "$LOGF"; try run_clean --all; check "clean.sh --all: dead tab reported" "$RC" "1"; case "$OUT" in *"Codex: its tab (t3) does not respond."*) echo "ok   clean.sh --all: dead tab message";; *) echo "FAIL clean.sh --all: $OUT"; FAIL=1;; esac
check "clean.sh --all excludes the planner" "$(grep -c 'terminal show --terminal t1' "$LOGF" || true)" "0"
check "clean.sh --all goes through the workers" "$(grep -c 'terminal show' "$LOGF")" "3"
check "clean.sh --msg" "$(run_clean --msg dev | sed "s#$TMP/home/.orca-roles#$KIT#g")" "$(cd "$TMP" && worker_msg "$C" dev)"

# Scratch folders: fixed per worktree and role, outside the worktree; the kit creates them and never empties or deletes them
SW="$TMP/scratch"; mkdir -p "$SW/main"; git -C "$SW/main" init -q; git -C "$SW/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$SW/main" worktree add -q "$SW/linked" -b other
S1="$(cd "$SW/main" && scratch_dir tester)"; S2="$(cd "$SW/main" && scratch_dir tester)"; S3="$(cd "$SW/linked" && scratch_dir tester)"
check "scratch_dir is stable" "$S1" "$S2"
case "$S1" in "$KIT/tmp/"?*/tester) echo "ok   scratch_dir is absolute, under \$KIT/tmp and ends in the role";; *) echo "FAIL scratch_dir shape: $S1"; FAIL=1;; esac
[ "$S1" != "$S3" ] && echo "ok   scratch_dir differs between two worktrees" || { echo "FAIL scratch_dir equal for two worktrees: $S1"; FAIL=1; }
check "scratch_dir differs per role" "$([ "$S1" != "$(cd "$SW/main" && scratch_dir dev)" ] && echo y)" "y"
case "$S1" in "$SW"/*|"$(cd "$SW" && pwd -P)"/*) echo "FAIL scratch_dir inside the worktree: $S1"; FAIL=1;; *) echo "ok   scratch_dir is outside the worktree";; esac
check "scratch_dir without a role fails" "$(cd "$SW/main" && scratch_dir "" || echo fail)" "fail"
# New contract: the kit never empties a scratch folder; clean.sh leaves it intact and resends the role with scratchDir
SD_DEV="$(cd "$TMP" && KIT="$TMP/home/.orca-roles" scratch_dir dev)"; mkdir -p "$SD_DEV/sub"; touch "$SD_DEV/f" "$SD_DEV/sub/g" "$SD_DEV/.hidden"
: > "$LOGF"; run_clean dev >/dev/null
check "clean.sh leaves the scratch folder content intact" "$([ -f "$SD_DEV/f" ] && [ -f "$SD_DEV/sub/g" ] && [ -f "$SD_DEV/.hidden" ] && echo y)" "y"
check "clean.sh resends the role with scratchDir" "$(grep -c -F "scratchDir=$SD_DEV" "$LOGF")" "1"
# scratch_dir from a subdirectory of the worktree is the same as from its root
mkdir -p "$SW/main/a/b"
check "scratch_dir from a subdirectory equals the root's" "$(cd "$SW/main/a/b" && scratch_dir tester)" "$S1"
check "scratch_dir from a subdirectory of a linked worktree" "$(mkdir -p "$SW/linked/x" && cd "$SW/linked/x" && scratch_dir tester)" "$S3"
# no script in bin/ deletes under the scratch root (rm, find -delete or rsync --delete aimed at $KIT/tmp or scratch_dir)
check "bin/ has no empty_scratch left" "$(grep -c 'empty_scratch' "$ROOT"/bin/*.sh | grep -vc ':0$' || true)" "0"
# prompts: earlier versions go to rev-<sha> folders, copies of the tree to copy/, and nobody deletes in scratchDir
check "common-workers.md: earlier versions in rev-<full sha>, read-only, copy-rev/" "$(grep -c 'rev-\$sha' "$ROOT/prompts/common-workers.md")$(grep -c 'rev-parse "<commit>^{commit}"' "$ROOT/prompts/common-workers.md")$(grep -c -- '--short' "$ROOT/prompts/common-workers.md" || true)$(grep -c 'copy-rev/' "$ROOT/prompts/common-workers.md")" "1101"
check "planner.md: earlier versions go to the Researcher's scratchDir rev-<full sha>" "$(grep -c 'scratchDir.*rev-<full sha>.*rev-parse "<commit>^{commit}"' "$ROOT/prompts/planner.md")" "1"
check "tester.md: its copy is <scratchDir>/copy/" "$(grep -c 'rsync -a --delete --exclude .git ./ <scratchDir>/copy/' "$ROOT/prompts/tester.md")" "1"
check "auditor.md: Experiments block uses <scratchDir>/copy/" "$(grep -c '^rsync -a --delete --exclude .git ./ <scratchDir>/copy/' "$ROOT/prompts/auditor.md")" "1"
check "no prompt tells an agent to delete or use /tmp" "$(grep -rnE '\brm\b|mktemp|/tmp|/var/folders' "$ROOT/prompts/" | wc -l | tr -d ' ')" "0"
rm -rf "$KIT/tmp"
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
for sec in '^## Your browser' 'browser-login.sh' 'browser_evaluate'; do grep -q "$sec" "$ROOT/prompts/e2e-tester.md" || { echo "FAIL e2e-tester.md without $sec"; FAIL=1; }; done
grep -q 'browser-login.sh' "$ROOT/prompts/planner.md" || { echo "FAIL planner.md without browser-login"; FAIL=1; }
grep -q 'orca-<service>.pid' "$ROOT/prompts/deployer.md" || { echo "FAIL deployer.md without services"; FAIL=1; }
echo "ok   E2E test prompts"

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
for r in planner dev deployer; do d="$(cd "$L" && KIT="$TMP/home/.orca-roles" scratch_dir $r)"; mkdir -p "$d/sub"; touch "$d/f" "$d/sub/g" "$d/.hidden"; done
try launch --reset; check "launch: --reset goes back to the configuration" "$RC:$(handles)" "0:PLANNER DEV DEPLOYER "
check "launch creates the scratch folder of each enabled role only" "$(for r in planner dev deployer tester; do [ -d "$(cd "$L" && KIT="$TMP/home/.orca-roles" scratch_dir $r)" ] && printf y || printf n; done)" "yyyn"
try launch --only dev; check "launch: --only" "$RC:$(handles)" "0:PLANNER DEV "
check "launch.sh leaves pre-seeded scratch content intact" "$(for r in planner dev deployer; do d="$(cd "$L" && KIT="$TMP/home/.orca-roles" scratch_dir $r)"; [ -f "$d/f" ] && [ -f "$d/sub/g" ] && [ -f "$d/.hidden" ] && printf y || printf n; done)" "yyy"
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

# The composer's extra session is recognized by its FIRST title (Claude Code renames it to "done") and closed by handle
printf '%s' '{"terminals":[{"handle":"x1","title":"VATE-40 Prueba","agentIdentity":"claude","preview":""},{"handle":"s1","title":"bash","agentIdentity":"","preview":""}]}' | seen_merge "" > "$TMP/seen.json"
printf '%s' '{"terminals":[{"handle":"x1","title":"done","agentIdentity":"claude","preview":""},{"handle":"x2","title":"other","agentIdentity":"claude","preview":"working on VATE-40 now"}]}' | seen_merge "$TMP/seen.json" > "$TMP/seen2.json"
check "seen_merge keeps the first title" "$(jq -r '.[] | select(.handle == "x1") | .title' "$TMP/seen2.json")" "VATE-40 Prueba"
check "seen_merge adds new terminals" "$(jq -r 'map(.handle) | join(" ")' "$TMP/seen2.json")" "s1 x1 x2"
check "composer_targets: first title or the key on screen; never shells or ours" "$(composer_targets "$TMP/seen2.json" '["x2"]' "$(composer_title_regex VATE-40 feat)" VATE-40 | tr '\n' ' ')" "x1 "
check "composer_targets: the key on screen counts" "$(composer_targets "$TMP/seen2.json" '[]' "$(composer_title_regex VATE-40 feat)" VATE-40 | tr '\n' ' ')" "x1 x2 "
check "composer_targets: nothing without a match" "$(composer_targets "$TMP/seen2.json" '[]' "$(composer_title_regex "" feat)" "")" ""
CP="$TMP/cproj"; mkdir -p "$CP" "$TMP/cbin"; git -C "$CP" init -q -b feat-x
COLOG="$TMP/corca.log"; : > "$COLOG"
cat > "$TMP/cbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$COLOG"
case "\$1 \$2" in
  "terminal create") while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; echo "{\"handle\":\"h-\$t\"}";;
  "terminal show") exit 1;;
  "terminal list")
    if [ -f "$TMP/clist.seen" ]; then t=done; else t=feat-x; : > "$TMP/clist.seen"; fi
    echo "{\"terminals\":[{\"handle\":\"x1\",\"title\":\"\$t\",\"agentIdentity\":\"claude\",\"preview\":\"\"},{\"handle\":\"s1\",\"title\":\"feat-x\",\"agentIdentity\":\"\",\"preview\":\"\"}]}";;
esac
exit 0
EOS
chmod +x "$TMP/cbin/orca"
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": true, "composerAgentWindowSeconds": 6, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" } } }
J
claunch() { (cd "$CP" && HOME="$TMP/home" PATH="$TMP/cbin:$PATH" "$TMP/home/.orca-roles/bin/launch.sh" >/dev/null 2>&1); }
claunch
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q "Closed x1" "$CP/.git/orca-roles-kickoff.log" 2>/dev/null && break; sleep 1; done
check "composer: closes the renamed tab by its first title" "$(grep -c '^Closed x1$' "$CP/.git/orca-roles-kickoff.log")" "1"
check "composer: closes it with terminal close --tab" "$(grep -c 'terminal close --terminal x1 --tab' "$COLOG")" "1"
check "composer: never touches a shell with the same title" "$(grep -c 'terminal close --terminal s1' "$COLOG" || true)" "0"
claunch
for _ in 1 2 3 4 5; do grep -q "Not a new worktree" "$CP/.git/orca-roles-kickoff.log" 2>/dev/null && break; sleep 1; done
check "composer: not looked for when resuming" "$(grep -c 'Not a new worktree' "$CP/.git/orca-roles-kickoff.log")" "1"

# The 'orca' alias the installer adds to ~/.bashrc: points to $ORCA_CLI_COMMAND in Orca's WSL terminals, nothing elsewhere
ALIAS_LINE="$(grep 'orca-roles: orca alias' "$ROOT/install.sh" | sed -e "s/^grep -q 'orca-roles: orca alias' \"\$RC\" 2>\/dev\/null || echo '//" -e "s/' >> \"\$RC\"\$//")"
check "orca alias: calls ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide bash -c "shopt -s expand_aliases; $ALIAS_LINE
orca worktree list")" "orca-ide:worktree list"
check "orca alias: nothing outside Orca" "$(PATH="/usr/bin:/bin" ORCA_CLI_COMMAND='' bash -c "shopt -s expand_aliases; $ALIAS_LINE
command -v orca || echo none")" "none"

# Removing a role: new-role --remove (only roles you created) and close-role.sh (closes its tab in this workspace)
cat > "$KIT/config.json" <<'J'
{ "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" } } }
J
printf '%s' '{"id":"sec-review","description":"reviews security","prompt":"# Role: SEC\n\n## Report\nx\n"}' > "$TMP/role.json"
newrole "$TMP/role.json" >/dev/null
rmrole() { (cd "$TMP" && HOME="$TMP/home" "$TMP/home/.orca-roles/bin/new-role.sh" --remove "$1" 2>&1); }
try rmrole sec-review; check "remove: a role you created" "$RC:$(jq -r '.roles | keys_unsorted | join(" ")' "$KIT/config.json"):$([ -f "$KIT/roles/sec-review.md" ] && echo prompt-left || echo prompt-gone)" "0:planner dev:prompt-gone"
[ -f "$KIT/config.json.bak" ] && jq -e '.roles["sec-review"]' "$KIT/config.json.bak" >/dev/null && echo "ok   remove: .bak keeps the role" || { echo "FAIL remove .bak"; FAIL=1; }
try rmrole dev; check "remove: a default role is refused" "$RC" "1"; case "$OUT" in *'"enabled": false'*) echo "ok   remove: suggests enabled false for a default role";; *) echo "FAIL remove default: $OUT"; FAIL=1;; esac
try rmrole planner; check "remove: the planner is refused" "$RC" "1"
try rmrole nobody; check "remove: an unknown role fails" "$RC" "1"
cat > "$KIT/config.json" <<'J'
{ "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" }, "sec": { "title": "Sec", "enabled": false } } }
J
printf 'PLANNER=t1\nDEV=t2\nSEC=t3\n' > "$TMP/state.env"
CRLOG="$TMP/crorca.log"; : > "$CRLOG"
cat > "$TMP/fakebin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$CRLOG"
case "\$*" in *"show --terminal t2 "*) exit 1;; esac
exit 0
EOS
chmod +x "$TMP/fakebin/orca"
closerole() { (cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/close-role.sh" "$@" 2>&1); }
try closerole Sec; check "close-role: by title" "$RC:$OUT" "0:Sec: tab closed (t3)."
check "close-role: closes the whole tab" "$(grep -c 'terminal close --terminal t3 --tab' "$CRLOG")" "1"
check "close-role: forgets its handle" "$(cut -d= -f1 "$TMP/state.env" | tr '\n' ' ')" "PLANNER DEV "
try closerole dev; check "close-role: a dead tab is just forgotten" "$RC" "0"; case "$OUT" in *"already gone"*"still enabled"*) echo "ok   close-role: warns that roles would reopen an enabled role";; *) echo "FAIL close-role enabled: $OUT"; FAIL=1;; esac
try closerole planner; check "close-role: never the planner" "$RC" "1"
try closerole nobody; check "close-role: unknown role" "$RC" "1"
rm -f "$TMP/fakebin/orca"

# The Planner does not block waiting for the workers
grep -q 'Never block waiting for the workers' "$ROOT/prompts/planner.md" && ! grep -q 'check --wait --types' "$ROOT/prompts/planner.md" && echo "ok   planner.md: waits without blocking" || { echo "FAIL planner.md still blocks in check --wait"; FAIL=1; }

# The repo is a Claude Code marketplace whose plugin is the kit's own
check "marketplace: lists the orca-roles plugin from ./plugin" "$(jq -r '.plugins[] | "\(.name) \(.source)"' "$ROOT/.claude-plugin/marketplace.json")" "orca-roles ./plugin"
check "marketplace: same name as the plugin" "$(jq -r '.plugins[0].name' "$ROOT/.claude-plugin/marketplace.json")" "$(jq -r '.name' "$ROOT/plugin/.claude-plugin/plugin.json")"
grep -q '^## Start here' "$ROOT/README.md" && [ "$(grep -n '^## ' "$ROOT/README.md" | head -1 | cut -d: -f2-)" = "## Start here: get Claude's help with the setup" ] && echo "ok   README starts with installing the guide" || { echo "FAIL README does not start with the guide"; FAIL=1; }

# Tighter steps: the rules from the review are in the prompts and the defaults
for pat in 'Scope: only what the user asked' 'Criteria as families with boundaries' 'Threat model and rejection threshold' 'Check the libraries first' 'contract decision' 'Fix rounds carry only what changed' 'do not try Jira'"'"'s REST API'; do
  grep -q "$pat" "$ROOT/prompts/planner.md" || { echo "FAIL planner.md without: $pat"; FAIL=1; }
done
grep -q 'maxSelfMutants' "$ROOT/prompts/tester.md" && grep -q 'family of inputs with its boundaries' "$ROOT/prompts/tester.md" || { echo "FAIL tester.md without self-mutation or families"; FAIL=1; }
grep -q 'Reject only from the threshold' "$ROOT/prompts/auditor.md" && grep -q 'rejectSeverity' "$ROOT/prompts/auditor.md" || { echo "FAIL auditor.md without the threshold"; FAIL=1; }
grep -q 'family with its boundaries' "$ROOT/prompts/dev.md" || { echo "FAIL dev.md without boundaries"; FAIL=1; }
check "defaults: Tester maxSelfMutants and Auditor rejectSeverity" "$(jq -c '[.roles.tester.params.maxSelfMutants, .roles.auditor.params.rejectSeverity]' "$ROOT/config.default.json")" '[5,"high"]'
echo "ok   prompts carry the review's rules"

# The composer's tab without Jira ("✳ Claude Code"): closed when Orca's setup script started the kit, never on a manual run
printf '%s' '[{"handle":"x1","title":"✳ Claude Code","agentIdentity":"claude"},{"handle":"s1","title":"bash","agentIdentity":null},{"handle":"h1","title":"Planner","agentIdentity":"claude"}]' > "$TMP/pre.json"
check "preexisting_agents: agent tabs outside the team only" "$(preexisting_agents "$TMP/pre.json" '["h1"]' | tr '\n' ' ')" "x1 "
SM="$TMP/smain"; mkdir -p "$SM" "$TMP/sbin"; git -C "$SM" init -q -b main; git -C "$SM" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
newwt() { git -C "$SM" worktree add -q -b "$2" "$1" 2>/dev/null; }   # a worktree created now, as Orca does
SLOG="$TMP/sorca.log"
cat > "$TMP/sbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$SLOG"
case "\$1 \$2" in
  "terminal create") while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; echo "{\"handle\":\"h-\$t\"}";;
  "terminal show") exit 1;;
  "terminal list") echo '{"terminals":[{"handle":"x1","title":"✳ Claude Code","agentIdentity":"claude","preview":""},{"handle":"s1","title":"bash","agentIdentity":null,"preview":""}]}';;
esac
exit 0
EOS
chmod +x "$TMP/sbin/orca"
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": true, "composerAgentWindowSeconds": 6, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" } } }
J
waitlog() { for _ in 1 2 3 4 5 6 7 8 9 10; do grep -qE "$2" "$1" 2>/dev/null && return 0; sleep 1; done; return 0; }
slaunch() { (cd "$1" && HOME="$TMP/home" PATH="$TMP/sbin:$PATH" ORCA_ROOT_PATH="${2:-}" ORCA_WORKTREE_PATH="${2:-}" "$TMP/home/.orca-roles/bin/launch.sh" >/dev/null 2>&1); }
gd() { (cd "$1" && cd "$(git rev-parse --git-dir)" && pwd); }
SP="$TMP/swt1"; newwt "$SP" feat-y; : > "$SLOG"; slaunch "$SP" "$SM"
waitlog "$(gd "$SP")/orca-roles-kickoff.log" 'Closed x1|No composer'
check "composer without Jira: closed on a worktree Orca just created" "$(grep -c '^Closed x1$' "$(gd "$SP")/orca-roles-kickoff.log")" "1"
check "composer without Jira: the shell is never closed" "$(grep -c 'terminal close --terminal s1' "$SLOG" || true)" "0"
grep -q "Started by Orca's setup script on a worktree it just created" "$(gd "$SP")/orca-roles-launch.log" && echo "ok   launch.sh logs that Orca's setup started it" || { echo "FAIL launch.sh setup log"; FAIL=1; }
SP2="$TMP/swt2"; newwt "$SP2" feat-z; : > "$SLOG"; slaunch "$SP2" ""
waitlog "$(gd "$SP2")/orca-roles-kickoff.log" 'Closed x1|No composer|Not a new'
check "composer without Jira: a manual run closes nothing" "$(grep -c 'terminal close' "$SLOG" || true)" "0"
SP3="$TMP/swt3"; newwt "$SP3" feat-old; touch -t 202001010000 "$(gd "$SP3")/gitdir"; : > "$SLOG"; slaunch "$SP3" "$SM"
waitlog "$(gd "$SP3")/orca-roles-kickoff.log" 'Closed x1|No composer|Not a new'
check "composer: setup variables in an old worktree (roles typed in the setup tab) close nothing" "$(grep -c 'terminal close' "$SLOG" || true)" "0"
grep -q "Not a worktree Orca is creating right now" "$(gd "$SP3")/orca-roles-launch.log" && echo "ok   launch.sh tells an old worktree apart" || { echo "FAIL launch.sh old worktree log"; FAIL=1; }
SP4="$TMP/sproj4"; mkdir -p "$SP4"; git -C "$SP4" init -q -b main; : > "$SLOG"; slaunch "$SP4" "$SP4"
waitlog "$SP4/.git/orca-roles-kickoff.log" 'Closed x1|No composer|Not a new'
check "composer: a main checkout is never taken for a new worktree" "$(grep -c 'terminal close' "$SLOG" || true)" "0"
# A tab whose agent is gone (Ctrl+C) counts as dead: roles closes it and opens a new one; custom agents are not checked
DP="$TMP/dproj"; mkdir -p "$DP" "$TMP/dbin"; git -C "$DP" init -q -b main
printf 'PLANNER=t-pl\nDEV=t-dev\nCU=t-cu\nTST=t-orp\n' > "$DP/.git/orca-roles.env"
DLOG="$TMP/dorca.log"; : > "$DLOG"
cat > "$TMP/dbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$DLOG"
case "\$1 \$2" in
  "terminal create") while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; echo "{\"handle\":\"h-\$t\"}";;
  "terminal show") case "\$*" in *t-dev*|*t-cu*) echo '{"result":{"terminal":{"agentIdentity":null}}}';; *t-orp*) echo '{"result":{"terminal":{"agentIdentity":"claude","orphaned":true,"connected":false}}}';; *) echo '{"result":{"terminal":{"agentIdentity":"claude","orphaned":false}}}';; esac;;
esac
exit 0
EOS
chmod +x "$TMP/dbin/orca"
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" }, "cu": { "title": "Custom", "agent": "custom", "command": "x" }, "tst": { "title": "Tst" } } }
J
OUT="$(cd "$DP" && HOME="$TMP/home" PATH="$TMP/dbin:$PATH" ORCA_ROLES_AGENT_CHECKS=1 "$TMP/home/.orca-roles/bin/launch.sh" 2>&1)"
case "$OUT" in *"The agent in the tab of Dev (t-dev) is gone"*) echo "ok   dead agent: detected in a live tab";; *) echo "FAIL dead agent: $OUT"; FAIL=1;; esac
check "dead agent: its old tab is closed" "$(grep -c 'terminal close --terminal t-dev --tab' "$DLOG")" "1"
check "dead agent: a new tab replaces it" "$(cut -d= -f2 "$DP/.git/orca-roles.env" | tr '\n' ' ')" "t-pl h-Dev t-cu h-Tst "
check "dead agent: custom agents are not checked" "$(grep -c 'terminal close --terminal t-cu' "$DLOG" || true)" "0"
case "$OUT" in *"The tab of Tst (t-orp) was closed but Orca kept its session running"*) echo "ok   orphaned session: detected";; *) echo "FAIL orphaned: $OUT"; FAIL=1;; esac
check "orphaned session: ended" "$(grep -c 'terminal close --terminal t-orp' "$DLOG")" "1"
check "E1: non-Claude workers run Orca's commands in the foreground" "$(worker_msg "$KIT/config.json" cu | grep -c 'in the foreground')" "1"
check "E1: Claude workers get no extra instruction" "$(worker_msg "$KIT/config.json" dev | grep -c 'in the foreground' || true)" "0"
grep -q 'Watch for silent workers' "$ROOT/prompts/planner.md" && echo "ok   G: the Planner watches for silent workers" || { echo "FAIL planner.md without silent workers"; FAIL=1; }
# Jira/GitHub only with the user's yes; resource caps for the Tester and the Auditor
grep -q "Nothing leaves the worktree without the user's explicit yes" "$ROOT/prompts/planner.md" && echo "ok   planner.md: Jira/GitHub only with approval" || { echo "FAIL planner.md: approval rule"; FAIL=1; }
grep -q 'Never write to Jira, GitHub' "$ROOT/prompts/common-workers.md" && echo "ok   common-workers.md: workers never write to Jira/GitHub" || { echo "FAIL common-workers.md: Jira/GitHub rule"; FAIL=1; }
grep -q '^## Coming back with your memory' "$ROOT/prompts/planner.md" && echo "ok   planner.md: coming back with memory" || { echo "FAIL planner.md: memory section"; FAIL=1; }
for r in tester auditor; do grep -q 'No GPU' "$ROOT/prompts/$r.md" && grep -q 'maxWorkers' "$ROOT/prompts/$r.md" || { echo "FAIL $r.md: resource caps"; FAIL=1; }; done; echo "ok   tester/auditor prompts: CPU, threads and GPU caps"
check "default config: tester and auditor lowered priority" "$(jq -r '[.roles.tester.nice, .roles.auditor.nice] | join(",")' "$ROOT/config.default.json")" "10,10"
check "default config: thread caps and no GPU" "$(jq -r '.roles.auditor.env | [.OMP_NUM_THREADS, .GOMAXPROCS, .CUDA_VISIBLE_DEVICES] | join("|")' "$ROOT/config.default.json")" "2|2|"
check "default config: auditor maxWorkers" "$(jq -r '.roles.auditor.params.maxWorkers' "$ROOT/config.default.json")" "2"
# agent.sh: nice -n and --resume
cat > "$KIT/config.json" <<'J'
{ "defaults": { "mcp": "all", "agent": "claude" }, "mcpServers": {}, "roles": { "tester": { "nice": 10, "env": { "GOMAXPROCS": "2" } }, "dev": {}, "cx": { "agent": "codex" } } }
J
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$TMP/fakebin/claude"; cp "$TMP/fakebin/claude" "$TMP/fakebin/codex"; chmod +x "$TMP/fakebin/claude" "$TMP/fakebin/codex"
printf '#!/bin/sh\nprintf "nice %%s %%s\\n" "$1" "$2"; shift 2; echo "GOMAXPROCS=$GOMAXPROCS"; exec "$@"\n' > "$TMP/fakebin/nice"; chmod +x "$TMP/fakebin/nice"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" tester | tr '\n' ' ')"
case "$OUT" in "nice -n 10 GOMAXPROCS=2 --add-dir "*) echo "ok   agent.sh: nice -n and the role's env";; *) echo "FAIL agent.sh nice: $OUT"; FAIL=1;; esac
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" dev --resume abc-123 | tr '\n' ' ')"
case "$OUT" in "--add-dir "*"--resume abc-123 "*) echo "ok   agent.sh: --resume passes the session to claude";; *) echo "FAIL agent.sh resume: $OUT"; FAIL=1;; esac
case "$OUT" in nice*) echo "FAIL agent.sh: nice without the option"; FAIL=1;; *) echo "ok   agent.sh: no nice without the option";; esac
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" cx --resume abc-123 2>&1 | tr '\n' ' ')"
case "$OUT" in *"--resume only applies to claude"*) echo "ok   agent.sh: --resume ignored for codex";; *) echo "FAIL agent.sh codex resume: $OUT"; FAIL=1;; esac
# agent.sh: --add-dir <scratch> only for claude agents (the fake claude and codex echo their arguments)
SDT="$(cd "$TMP" && KIT="$TMP/home/.orca-roles" scratch_dir tester)"; mkdir -p "$SDT/sub"; touch "$SDT/f" "$SDT/sub/g" "$SDT/.hidden"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" tester | tr '\n' ' ')"
case "$OUT" in *"--add-dir $SDT "*) echo "ok   agent.sh claude: --add-dir <scratch>";; *) echo "FAIL agent.sh claude scratch: $OUT"; FAIL=1;; esac
check "agent.sh claude creates the scratch folder" "$([ -d "$SDT" ] && echo y)" "y"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" cx | tr '\n' ' ')"
case "$OUT" in *"$KIT/tmp"*|*"$TMP/home/.orca-roles/tmp"*|*"--add-dir"*) echo "FAIL agent.sh codex got the scratch folder: $OUT"; FAIL=1;; *) echo "ok   agent.sh codex: no --add-dir <scratch>";; esac
check "agent.sh leaves pre-seeded scratch content intact" "$([ -f "$SDT/f" ] && [ -f "$SDT/sub/g" ] && [ -f "$SDT/.hidden" ] && echo y)" "y"
rm -f "$TMP/fakebin/claude" "$TMP/fakebin/codex" "$TMP/fakebin/nice"
# After a restart, Orca restores the tabs with new handles: the kit finds each one by its ptyId, reads the resumed session and reopens the role with it
RP="$TMP/rproj"; mkdir -p "$RP" "$TMP/rbin"; git -C "$RP" init -q -b main
printf 'PLANNER=old-pl\nDEV=old-dev\nTST=old-tst\n' > "$RP/.git/orca-roles.env"
printf 'PLANNER=wt@@p1\nDEV=wt@@p2\nTST=wt@@p3\n' > "$RP/.git/orca-roles.pty"
RLOG="$TMP/rorca.log"; : > "$RLOG"
cat > "$TMP/rbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$RLOG"
case "\$1 \$2" in
  "terminal list") echo '{"terminals":[{"handle":"rs-pl","ptyId":"wt@@p1","title":"x"},{"handle":"rs-dev","ptyId":"wt@@p2","title":"y"},{"handle":"other","ptyId":"wt@@p9","title":"z"}]}';;
  "terminal create") while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; echo "{\"handle\":\"new-\$t\"}";;
  "terminal show") case "\$*" in *old-*) exit 1;; *new-Planner*) echo '{"result":{"terminal":{"ptyId":"wt@@n1","agentIdentity":"claude"}}}';; *new-Dev*) echo '{"result":{"terminal":{"ptyId":"wt@@n2","agentIdentity":"claude"}}}';; *) echo '{"result":{"terminal":{"ptyId":"wt@@n3","agentIdentity":"claude"}}}';; esac;;
esac
exit 0
EOS
printf '#!/bin/sh\ncase "$1" in rs-pl) echo 11111111-2222-3333-4444-555555555555;; esac\n' > "$TMP/rbin/session-of"   # only the Planner's session is readable
printf '#!/bin/sh\necho "$*" > "%s/rkick.args"\n' "$TMP" > "$TMP/rbin/kickoff"
chmod +x "$TMP/rbin/orca" "$TMP/rbin/session-of" "$TMP/rbin/kickoff"
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" }, "tst": { "title": "Tst" } } }
J
OUT="$(cd "$RP" && HOME="$TMP/home" PATH="$TMP/rbin:$PATH" ORCA_ROLES_AGENT_CHECKS=1 ORCA_ROLES_SESSION_OF="$TMP/rbin/session-of" ORCA_ROLES_KICKOFF="$TMP/rbin/kickoff" "$TMP/home/.orca-roles/bin/launch.sh" 2>&1)"
case "$OUT" in *"Orca restored the tab of Planner after a restart (rs-pl) without the kit's settings; reopening it with its conversation (11111111-2222-3333-4444-555555555555)"*) echo "ok   restart: restored Planner tab recognized by ptyId";; *) echo "FAIL restart planner: $OUT"; FAIL=1;; esac
case "$OUT" in *"Orca restored the tab of Dev after a restart (rs-dev), but its session could not be read"*) echo "ok   restart: restored tab without a readable session starts fresh";; *) echo "FAIL restart dev: $OUT"; FAIL=1;; esac
case "$OUT" in *"The previous tab of Tst (old-tst) no longer exists"*) echo "ok   restart: a tab Orca did not restore starts fresh";; *) echo "FAIL restart tst: $OUT"; FAIL=1;; esac
check "restart: the restored tabs are closed, nothing else" "$(grep -E 'terminal close' "$RLOG" | sed 's/ --tab --json//' | tr '\n' ' ')" "terminal close --terminal rs-pl terminal close --terminal rs-dev "
check "restart: the Planner reopens with --resume and the kit's launcher" "$(grep -c "agent.sh' planner --resume 11111111-2222-3333-4444-555555555555 --json" "$RLOG")" "1"
check "restart: Dev reopens without --resume" "$(grep -c "agent.sh' dev --json" "$RLOG")" "1"
check "restart: new handles saved" "$(cut -d= -f2 "$RP/.git/orca-roles.env" | tr '\n' ' ')" "new-Planner new-Dev new-Tst "
check "restart: new terminal identities saved" "$(cut -d= -f2 "$RP/.git/orca-roles.pty" | tr '\n' ' ')" "wt@@n1 wt@@n2 wt@@n3 "
sleep 1; check "restart: kickoff gets the resumed and the remembered roles" "$(cut -d" " -f2- "$TMP/rkick.args" | sed "s#$RP/.git#GD#g")" "GD/orca-roles.env GD/orca-roles.config.json  planner dev tst  dev tst  planner"
M4="$(planner_msg "$KIT/config.json" "planner dev" "$RP/.git/orca-roles.env" "" "" 2)"
case "$M4" in *"you are BACK after a restart, with your previous conversation"*"Coming back with your memory"*) echo "ok   planner_msg: back with memory";; *) echo "FAIL planner_msg memory: $M4"; FAIL=1;; esac
case "$(worker_back_msg "$KIT/config.json" dev new-Dev)" in *"Your terminal handle is now new-Dev"*"do not continue it on your own"*) echo "ok   worker_back_msg";; *) echo "FAIL worker_back_msg"; FAIL=1;; esac
# close-role.sh forgets the role's terminal identity too
printf 'PLANNER=a\nDEV=b\n' > "$RP/.git/orca-roles.env"; printf 'PLANNER=wt@@a\nDEV=wt@@b\n' > "$RP/.git/orca-roles.pty"; cp "$KIT/config.json" "$RP/.git/orca-roles.config.json"
(cd "$RP" && HOME="$TMP/home" PATH="$TMP/rbin:$PATH" "$TMP/home/.orca-roles/bin/close-role.sh" dev >/dev/null 2>&1)
check "close-role.sh: drops the identity of the closed role" "$(cat "$RP/.git/orca-roles.pty" | tr '\n' ' ')" "PLANNER=wt@@a "

sleep 1

[ "$FAIL" = 0 ] && echo "ALL OK" || { echo "FAILURES"; exit 1; }
