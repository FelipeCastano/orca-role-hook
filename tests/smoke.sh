#!/usr/bin/env bash
# orca-roles smoke tests: configuration, inheritance, per-project merge, update and the kit's scripts.
# Usage: tests/smoke.sh                  all sections, in order (does not touch ~/.orca-roles)
#        tests/smoke.sh <section>...     only those sections, in the given order
#        tests/smoke.sh --list           the section names, one per line
set -euo pipefail
SECTIONS="syntax prompts output-rules config planner-msg clean scratch prompt-rules cleanup-msg mcp mcp-placeholders custom-command jira-key composer-title project-config mcp-gitdir empty-lists cli-shim roles-yaml launch-overrides launch status modes new-role-modes planner-skill wizard role-notes plugin-dirs composer-session orca-alias remove-role prompts-misc composer-tab dead-tab agent-flags restart trust-folder codex-custom prompt-paths new-role-repo install-flat checkpoint guard model-check models cli"
if [ "${1:-}" = --list ]; then printf '%s\n' $SECTIONS; exit 0; fi
for s in "$@"; do
  known=0; for k in $SECTIONS; do [ "$k" = "$s" ] && known=1; done
  [ "$known" = 1 ] || { echo "smoke.sh: unknown section '$s'. Sections:"; printf '  %s\n' $SECTIONS; } >&2
  [ "$known" = 1 ] || exit 2
done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; DONE=0
on_exit() { local rc=$?; rm -rf "$TMP"; if [ "$DONE" != 1 ] && [ "$rc" = 0 ]; then echo "smoke.sh: ended before its summary" >&2; exit 1; fi; }
trap on_exit EXIT   # bash 3.2 can exit 0 on an unbound variable
export KIT="$TMP/kit"; mkdir -p "$KIT"
cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$KIT/"; chmod +x "$KIT"/bin/*.sh
. "$KIT/bin/lib.sh"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3], got [$2]"; FAIL=1; fi; }
blk_start() { F0=$FAIL; FAIL=0; }
blk_end() { [ "$FAIL" = 0 ] && echo "ok   $1"; [ "$F0" = 0 ] || FAIL=1; return 0; }
try() { if OUT="$("$@")"; then RC=0; else RC=$?; fi; }   # captures output and exit code without tripping set -e
mkdir -p "$TMP/fakebin" "$TMP/home"; ln -sfn "$KIT" "$TMP/home/.orca-roles"   # fake HOME: ~/.orca-roles → test kit
PROJ="$TMP/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
echo '{ "roles": { "dev": { "mcp": [] }, "tester": { "enabled": true } }, "settings": { "jiraHandoff": false } }' > "$PROJ/.orca-roles.json"
newrole() { (cd "$TMP" && HOME="$TMP/home" "$TMP/home/.orca-roles/bin/new-role.sh" --from-json "$1" 2>&1); }

write_clean_config() {
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1 }, "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": {
    "planner": { "title": "Planner" },
    "dev": { "title": "Dev", "params": { "a": 1 } },
    "cx": { "title": "Codex", "agent": "codex" },
    "cu": { "title": "Custom", "agent": "custom", "command": "x" },
    "cc": { "title": "Custom2", "agent": "custom", "command": "x", "clearCommand": "/reset" } } }
J
}
write_placeholders_config() {
cat > "$KIT/config.json" <<'J'
{ "defaults": { "mcp": [] }, "mcpServers": {
    "pw": { "command": "npx", "args": ["-y", "@playwright/mcp@latest", "--headless", "--storage-state", "{browserState}", "--output-dir", "{worktree}/{evidenceDir}"], "env": { "P": "{project}", "K": "{kit}" } },
    "h": { "type": "http", "url": "http://{home}/x" } },
  "roles": { "vt": { "agent": "custom", "command": "run {mcp}", "mcp": ["pw", "h"], "params": { "evidenceDir": "ev" } },
             "other": { "agent": "custom", "command": "run {mcp}", "mcp": ["pw"] } } }
J
}
write_launch_config() {
cat > "$KIT/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev", "model": "m-dev" },
             "tester": { "title": "Tester", "enabled": false }, "deployer": { "title": "Deployer" } } }
J
}
fake_bash() {   # bash -lc prints the command instead of running it
printf '#!/bin/sh\n[ "$1" = -lc ] && { echo "$2"; exit 0; }\nexec /bin/bash "$@"\n' > "$TMP/fakebin/bash"; chmod +x "$TMP/fakebin/bash"
}
pk_setup() {
PK="$TMP/pk"; PH="$TMP/pkhome"; mkdir -p "$PK" "$PH" "$TMP/pkbin"
cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$PK/"; chmod +x "$PK"/bin/*.sh
ln -sfn "$PK" "$PH/.orca-roles"; PKL="$PH/.orca-roles"
PKC="$PK/config.default.json"
}
cli_shim_dir() {
mkdir -p "$TMP/cli"; printf '#!/bin/sh\necho "orca-ide:$*"\n' > "$TMP/cli/orca-ide"; chmod +x "$TMP/cli/orca-ide"
}

clean_fixture() {
write_clean_config
C="$KIT/config.json"
printf 'PLANNER=t1\nDEV=t2\nCX=t3\nCU=t4\n' > "$TMP/state.env"
LOGF="$TMP/orca.log"; : > "$LOGF"
cat > "$TMP/fakebin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$LOGF"
case "\$*" in *"--terminal t3 "*) [ "\$2" = show ] && exit 1;; esac
exit 0
EOS
chmod +x "$TMP/fakebin/orca"
run_clean() { (cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/clean.sh" "$@" 2>&1); }
}
tf_setup() {
TF="$TMP/tf"; mkdir -p "$TF/wt"
TFD="$(cd "$TF/wt" && pwd -P)"
tf_run() { # <home> [hook]: runs trust_folder in the worktree with that fake HOME; stdout -> $TF/out, stderr -> $TF/err, rc -> $TF/rc
  (cd "$TF/wt" && HOME="$1" ORCA_ROLES_TRUST_HOOK="${2:-}" trust_folder >"$TF/out" 2>"$TF/err"; echo $? >"$TF/rc") || true
}
tf_trusted() { jq -r --arg d "$TFD" '.projects[$d].hasTrustDialogAccepted // false' "$1" 2>/dev/null; }
tf_left() { find "$1" -name '.claude.json.orca-roles.*' 2>/dev/null | wc -l | tr -d ' '; }
TFJ='{"oauthAccount":{"email":"a@b"},"projects":{"/other":{"hasTrustDialogAccepted":true}}}'
}

sec_syntax() {
# Syntax and JSON
for f in "$ROOT"/install.sh "$ROOT"/bin/*.sh "$ROOT"/tests/*.sh; do bash -n "$f"; done; echo "ok   bash syntax"
jq empty "$ROOT/config.default.json"; echo "ok   config.default.json is JSON"
}

sec_prompts() {
# Every prompt follows the pattern
for p in "$ROOT"/prompts/programmer/*.md; do
  n="$(basename "$p" .md)"; [ "$n" = common-workers ] && continue
  for sec in '^# Role: ' '^## When you receive a task' '^## Limits' '^## Parameters' '^## Report' '^Now reply only'; do
    [ "$n" = planner ] && case "$sec" in '^## When you receive a task'|'^## Report'|'^Now reply only') continue;; esac
    grep -qE "$sec" "$p" || { echo "FAIL prompts/programmer/$n.md: missing section $sec"; FAIL=1; }
  done
  [ "$n" = planner ] || awk '/^## Report/{f=1;next} /^## /{f=0} f' "$p" | grep -qF 'following the Output rules' || { echo "FAIL prompts/programmer/$n.md: its Report does not point to the Output rules"; FAIL=1; }
done
grep -q '^## Code review method' "$ROOT/prompts/programmer/auditor.md" || { echo "FAIL auditor.md without its method"; FAIL=1; }
grep -q '^## Plan review method' "$ROOT/prompts/programmer/planner.md" || { echo "FAIL planner.md without its method"; FAIL=1; }
grep -q '^## Resuming a workspace after a restart' "$ROOT/prompts/programmer/planner.md" || { echo "FAIL planner.md without the resume section"; FAIL=1; }
grep -q 'reply to the user in the language they write to you in' "$ROOT/prompts/programmer/planner.md" || { echo "FAIL planner.md does not reply in the user's language"; FAIL=1; }
echo "ok   prompt pattern"
grep -q 'No heartbeats' "$ROOT/prompts/programmer/common-workers.md" || { echo "FAIL common-workers.md: falta la regla de no enviar heartbeats"; FAIL=1; }
grep -q 'lastOutputAt' "$ROOT/prompts/programmer/planner.md" || { echo "FAIL planner.md: la detección de workers silenciosos debe usar lastOutputAt"; FAIL=1; }
grep -q 'last_heartbeat_at' "$ROOT/prompts/programmer/planner.md" && { echo "FAIL planner.md: aún depende de last_heartbeat_at"; FAIL=1; }
echo "ok   heartbeats: workers no laten, planner vigila por lastOutputAt"
for p in common-workers planner; do grep -q 'No names of people anywhere you write' "$ROOT/prompts/programmer/$p.md" || { echo "FAIL $p.md: missing the no-names-of-people rule"; FAIL=1; }; done
grep -q 'No new code comments unless the repo' "$ROOT/prompts/programmer/common-workers.md" || { echo "FAIL common-workers.md: missing the comments rule"; FAIL=1; }
grep -q 'Names and stray comments' "$ROOT/prompts/programmer/auditor.md" || { echo "FAIL auditor.md: missing the names/comments finding"; FAIL=1; }
echo "ok   rules: no names of people, comments only if the repo uses them, auditor finding"
for p in common-workers planner; do
  r=$(grep 'No names of people anywhere you write' "$ROOT/prompts/programmer/$p.md" || true)
  for k in 'Handles (`@user`) and email addresses count as names' '"the repo owner"' 'not `<name>_test_user`' 'not "as <name> asked"' 'Names of products, libraries, companies and services'; do
    printf '%s' "$r" | grep -qF -- "$k" || { echo "FAIL $p.md: the no-names rule lost: $k"; FAIL=1; }
  done
done
grep 'No new code comments unless the repo' "$ROOT/prompts/programmer/common-workers.md" | grep -qF 'Never delete existing comments' || { echo "FAIL common-workers.md: the comments rule lost 'never delete existing comments'"; FAIL=1; }
grep 'No new code comments unless the repo' "$ROOT/prompts/programmer/common-workers.md" | grep -qF 'narrates the change' || { echo "FAIL common-workers.md: the comments rule lost 'never narrate the change'"; FAIL=1; }
a=$(grep 'Names and stray comments' "$ROOT/prompts/programmer/auditor.md" || true)
for k in 'handle or an email address' '**low** severity' 'Owner: **Dev** for code, **Tester** for tests'; do
  printf '%s' "$a" | grep -qF -- "$k" || { echo "FAIL auditor.md: the names/comments finding lost: $k"; FAIL=1; }
done
# the examples use placeholders, not real people
grep -rEq '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z.]{2,}' "$ROOT/prompts/" && { echo "FAIL prompts contain an email address"; FAIL=1; }
for p in common-workers planner; do
  at=$(grep -n 'never carry attribution to an AI' "$ROOT/prompts/programmer/$p.md" | head -1 | cut -d: -f1 || true)
  al=$(grep 'never carry attribution to an AI' "$ROOT/prompts/programmer/$p.md" | head -1 || true)
  for k in 'git log -1 --format=%B' 'git commit --amend'; do
    printf '%s' "$al" | grep -qF -- "$k" || { echo "FAIL $p.md: the AI-attribution rule lost: $k"; FAIL=1; }
  done
  nn=$(grep -n 'No names of people anywhere you write' "$ROOT/prompts/programmer/$p.md" | head -1 | cut -d: -f1 || true)
  [ -n "$at" ] && [ -n "$nn" ] && [ "$nn" -eq $((at + 1)) ] || { echo "FAIL $p.md: the no-names rule must sit right after the AI-attribution rule"; FAIL=1; }
  grep -qF "Merge pull request #N from <handle>/<branch>" "$ROOT/prompts/programmer/$p.md" || { echo "FAIL $p.md: the commit rule lost the GitHub merge-subject warning"; FAIL=1; }
done
c=$(grep 'No new code comments unless the repo' "$ROOT/prompts/programmer/common-workers.md" || true)
for k in 'comment density' 'CLAUDE.md' 'CONTRIBUTING' 'linter' 'none at all in a repo whose code carries none'; do
  printf '%s' "$c" | grep -qF -- "$k" || { echo "FAIL common-workers.md: the comments rule lost: $k"; FAIL=1; }
done
pass=$(awk '/^### Passes/{f=1;next} /^### /{f=0} f' "$ROOT/prompts/programmer/auditor.md" | grep 'Names and stray comments' || true)
printf '%s' "$pass" | grep -qF 'Jira' || { echo "FAIL auditor.md: the names/comments pass must live under '### Passes' and cover Jira"; FAIL=1; }
echo "ok   rules: key content pinned, examples use placeholders"

# Every role in the config has a prompt
for r in $(jq -r '.roles | keys_unsorted[]' "$KIT/config.default.json"); do
  [ -f "$(prompt_of "$KIT/config.default.json" "$r")" ] || { echo "FAIL role $r without a prompt"; FAIL=1; }
done; echo "ok   prompts of the default roles"
}

# The Output rules: pinned inside the section (not anywhere in the file), by anchor phrases
sec_output_rules() {
CW="$ROOT/prompts/programmer/common-workers.md"
OUTSEC="$(awk '/^## Output$/{f=1;next} /^## /{f=0} f' "$CW")"
[ -n "$OUTSEC" ] || { echo "FAIL common-workers.md: missing the Output section"; FAIL=1; }
for frag in 'Always write in English' 'Repo artifacts (code, commits, docs) still follow' 'no narration between tool calls' 'no recap' 'keep negations, numbers, units, paths, file:line and ids' 'is not written in telegraphic style' 'self-contained and complete' 'Never write "see the file in scratchDir"' 'full, unambiguous sentences'; do
  printf '%s' "$OUTSEC" | grep -qF "$frag" || { echo "FAIL common-workers.md: Output section lost '$frag'"; FAIL=1; }
done
WRAP="$(grep -F 'Never wrap commands in' "$CW" || true)"
for frag in 'Never wrap commands in `bash -c` or `sh -c`' 'save it as a script in `scratchDir`' 'the shell may be zsh'; do
  printf '%s' "$WRAP" | grep -qF -- "$frag" || { echo "FAIL common-workers.md: the wrapped-commands rule lost '$frag'"; FAIL=1; }
done
grep -qF "3-sentence" "$CW" && grep -qF -- '--report-path' "$CW" || { echo "FAIL common-workers.md: lost the override of the preamble's report instructions"; FAIL=1; }
PL="$(grep 'Specs are written in English and stay compact' "$ROOT/prompts/programmer/planner.md" || true)"
for frag in 'Do not repeat rules the worker prompts already carry' 'point to files and lines' 'self-contained about the task' 'threat model and rejection threshold' 'with the user you talk as usual' 'Literal strings stay in their original language'; do
  printf '%s' "$PL" | grep -qF "$frag" || { echo "FAIL planner.md: compact-specs bullet lost '$frag'"; FAIL=1; }
done
PLP="$ROOT/prompts/programmer/planner.md"
CONV="$(grep 'follows the repository.s own conventions, checked every time' "$PLP" || true)"
for frag in 'checked every time' 'git log -15' 'gh pr list --state merged' 'gh pr view' 'pull_request_template.md' 'glab mr list --merged' '.gitlab/merge_request_templates/' 'subTaskIssueTypes()' 'gh pr view <n> --comments' 'pulls/<n>/comments' 'Jira issue or subtask' 'For a Jira comment' 'Never reuse a format remembered' 'without re-reading'; do
  printf '%s' "$CONV" | grep -qF "$frag" || { echo "FAIL planner.md: convention-check bullet lost '$frag'"; FAIL=1; }
done
for frag in 'no history to read' 'the command fails or returns nothing' 'tell the user so and propose a format for them to confirm'; do
  printf '%s' "$CONV" | grep -qF "$frag" || { echo "FAIL planner.md: convention-check bullet lost the no-history fallback '$frag'"; FAIL=1; }
done
CMT="$(grep 'One commit per step, made at close' "$PLP" || true)"
printf '%s' "$CMT" | grep -qF "only on the user's explicit yes to that commit, before the next step opens" || { echo "FAIL planner.md: the one-commit rule lost the explicit yes"; FAIL=1; }
CMT2="$(grep 'One commit per step, now' "$PLP" || true)"
for frag in 'show the user the full message and the list of files' 'commit only on a clear yes to that commit' 'Approving the plan, the step or the Tester' 'is not approving the commit' 'If they ask for changes, show it again' '"ok, continue"' 'ask again' 'decline or defer the commit, ask what to do with the uncommitted changes' 'after the convention check in "Limits"' '`git status`, `git diff --stat`'; do
  printf '%s' "$CMT2" | grep -qF "$frag" || { echo "FAIL planner.md: step-close commit rule lost '$frag'"; FAIL=1; }
done
for pat in 'A step is \*\*open\*\* from its first task' 'Only one code task is in flight'; do
  printf '%s' "$(grep "$pat" "$PLP" || true)" | grep -qE 'commit is made|its commit is not made' || { echo "FAIL planner.md: '$pat' no longer keeps the step open until its commit is made"; FAIL=1; }
done
printf '%s' "$(grep 'Report to the user (see' "$PLP" || true)" | grep -qF "with the step's commit made, open the next step" || { echo "FAIL planner.md: the next step opens before the commit"; FAIL=1; }
printf '%s' "$(grep '\*\*Jira subtasks\.\*\*' "$PLP" || true)" | grep -qF 'after the convention check in "Limits"' || { echo "FAIL planner.md: Jira subtasks do not point to the convention check"; FAIL=1; }
[ "$(grep -cF 're-propose its close commit (re-running the convention check in "Limits")' "$PLP")" = 3 ] || { echo "FAIL planner.md: the recovery paths (resumed, back, cleared) must re-propose an uncommitted ACCEPTED step's commit"; FAIL=1; }
printf '%s' "$(grep '^- \*\*Nothing leaves the worktree' "$PLP" || true)" | grep -qF 'Approving the plan, a step or a commit is not approving a push or a Jira update' || { echo "FAIL planner.md: the nothing-leaves rule lost its approval sentence"; FAIL=1; }
grep -qF 'Nobody commits while the step is open' "$PLP" && { echo "FAIL planner.md: 'Nobody commits while the step is open' forbids the close commit"; FAIL=1; }
grep -qF "Nobody commits before the Tester's ACCEPTED" "$PLP" || { echo "FAIL planner.md: the one-commit bullet lost 'Nobody commits before the Tester's ACCEPTED'"; FAIL=1; }
grep -qF "Nobody commits before the Auditor's ACCEPTED" "$PLP" && { echo "FAIL planner.md: still says nobody commits before the Auditor's ACCEPTED"; FAIL=1; }
printf '%s' "$(grep '^8\. \*\*Close and report' "$PLP" || true)" | grep -qF "closes only with the Tester's ACCEPTED" || { echo "FAIL planner.md: step 8 must close on the Tester's ACCEPTED"; FAIL=1; }
printf '%s' "$(grep '^- A step only closes with ACCEPTED' "$PLP" || true)" | grep -qF 'ACCEPTED from the Tester (and the E2E-Tester and the Researcher if they took part)' || { echo "FAIL planner.md: Limits step-close rule is not the Tester's (plus E2E-Tester/Researcher)"; FAIL=1; }
printf '%s' "$(grep '^- A step only closes with ACCEPTED' "$PLP" || true)" | grep -qF 'Auditor' && { echo "FAIL planner.md: Limits step-close rule still names the Auditor"; FAIL=1; }
for pat in '^8\. \*\*Close and report' '^- A step only closes with ACCEPTED'; do
  printf '%s' "$(grep "$pat" "$PLP" || true)" | grep -qF 'and its commit made' || { echo "FAIL planner.md: '$pat' lost 'and its commit made'"; FAIL=1; }
done
printf '%s' "$(grep '^Steps are atomic' "$ROOT/README.md" || true)" | grep -qF "Nobody commits before the Tester's ACCEPTED" || { echo "FAIL README: lost the commit-after-ACCEPTED definition"; FAIL=1; }
for pat in '^5\. Tell the user, in a few lines: where you were' '^3\. Tell the user, in a few lines: the Run'; do
  printf '%s' "$(grep "$pat" "$PLP" || true)" | grep -qF 'and wait for the yes' || { echo "FAIL planner.md: recovery summary '$pat' lost 'wait for the yes'"; FAIL=1; }
done
for frag in 'open the next step only once the tree holds no changes from the previous step' '(commit, stash or branch, discard: the user decides and approves)' 'A step with nothing to commit (research only, no change needed) closes when the user agrees there is nothing to commit'; do
  printf '%s' "$CMT2" | grep -qF "$frag" || { echo "FAIL planner.md: step-close commit rule lost '$frag'"; FAIL=1; }
done
RPT="$(grep -A1 '^## Report to the user' "$PLP" | tail -1)"
printf '%s' "$RPT" | grep -qF 'the proposed commit, awaiting their yes' || { echo "FAIL planner.md: Report to the user lost the proposed commit awaiting the yes"; FAIL=1; }
RS="$(grep '^Steps are atomic and strictly sequential' "$ROOT/README.md" || true)"
for frag in 'and you say yes to it' 'match the format of the repo'"'"'s recent history, and Jira texts that of the Jira project'"'"'s recent ones' 're-reads them every time' 'The next step does not start until the commit is made'; do
  printf '%s' "$RS" | grep -qF "$frag" || { echo "FAIL README steps paragraph lost '$frag'"; FAIL=1; }
done
for p in dev tester auditor researcher e2e-tester deployer; do
  grep -qF 'following the Output rules' "$ROOT/prompts/programmer/$p.md" || { echo "FAIL $p.md: Report lost the pointer to the Output rules"; FAIL=1; }
done
grep -qF 'following the Output rules' "$ROOT/bin/new-role.sh" || { echo "FAIL new-role.sh: skeleton Report lacks the Output pointer"; FAIL=1; }
grep -qF 'following the Output rules' "$ROOT/plugin/skills/team/SKILL.md" || { echo "FAIL team SKILL.md: Report template lacks the Output pointer"; FAIL=1; }
RD="$(grep '^| `language` |' "$ROOT/README.md" || true)"
for frag in 'workers always write in English' '"language":"english"' "Claude Code's own \`language\` setting"; do
  printf '%s' "$RD" | grep -qF "$frag" || { echo "FAIL README language row lost '$frag'"; FAIL=1; }
done
# Anchor: workers get the English rule, the Planner does not
. "$ROOT/bin/lib.sh"
printf '%s' "$(role_anchor "$KIT/config.default.json" dev)" | grep -qF 'Always write in English' || { echo "FAIL role_anchor: workers lack the English rule"; FAIL=1; }
printf '%s' "$(role_anchor "$KIT/config.default.json" planner)" | grep -qF 'Always write in English' && { echo "FAIL role_anchor: the Planner got the English rule"; FAIL=1; }
echo "ok   output rules: pinned in their section, planner bullet, README, report pointers, anchor"
}

sec_config() {
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
check "prompt_of default" "$(prompt_of "$C" dev)" "$KIT/prompts/programmer/dev.md"
check "prompt_of with ~" "$(prompt_of "$C" extra)" "$HOME/x/extra.md"
check "regex_escape" "$(regex_escape 'feat/DEV-1.x+(y)')" 'feat/DEV-1\.x\+\(y\)'

# Merge with the project's .orca-roles.json (objects field by field, lists whole)
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
}

sec_planner_msg() {
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
M3="$(planner_msg "$KIT/config.json" "planner dev" "$TMP/state.env" "" "" 3)"
case "$M3" in (*"Handles: Dev=t2."*"conversation was cleared"*"After your conversation was cleared"*"Start there.") echo "ok   planner_msg: cleared mode";; (*) echo "FAIL planner_msg cleared: $M3"; FAIL=1;; esac
grep -q '^## After your conversation was cleared' "$ROOT/prompts/programmer/planner.md" && echo "ok   planner.md: section for the cleared mode" || { echo "FAIL planner.md without the cleared section"; FAIL=1; }
jq '.settings.language = "Spanish"' "$KIT/config.json" > "$TMP/lang.json"
case "$(planner_msg "$TMP/lang.json" "planner dev" "$TMP/state.env" "" "" 0)" in *"Always reply to the user in Spanish, whatever language they write in."*) echo "ok   planner_msg: settings.language";; *) echo "FAIL planner_msg language"; FAIL=1;; esac
check "default config: language auto" "$(jq -r '.settings.language' "$ROOT/config.default.json")" "auto"
}

sec_clean() {
# Worker cleanup: worker_msg, clear_command and clean.sh with a fake 'orca'
clean_fixture
check "worker_msg with parameters" "$(cd "$TMP" && worker_msg "$C" dev)" "Read $KIT/prompts/programmer/common-workers.md and $KIT/prompts/programmer/dev.md and adopt that role from now on. Follow its instructions to the letter. Configuration parameters: a=1, scratchDir=$(cd "$TMP" && scratch_dir dev)."
case "$(cd "$TMP" && worker_msg "$C" cx)" in *"a=1"*) echo "FAIL worker_msg without params shows another role's"; FAIL=1;; *"Configuration parameters: scratchDir=$KIT/tmp/"*) echo "ok   worker_msg without parameters (only scratchDir)";; *) echo "FAIL worker_msg without params: $(cd "$TMP" && worker_msg "$C" cx)"; FAIL=1;; esac
check "clear_command claude" "$(clear_command "$C" dev)" "/clear"
check "clear_command codex" "$(clear_command "$C" cx)" "/new"
check "clear_command custom undefined" "$(clear_command "$C" cu)" ""
check "clear_command explicit" "$(clear_command "$C" cc)" "/reset"
try run_clean dev
check "clean.sh dev: result" "$RC:$OUT" "0:Dev: context cleaned (/clear) and role resent."
check "clean.sh dev: sends /clear, waits and resends the role" "$(grep -c -E 'terminal send --terminal t2 --text /clear --enter|terminal wait --terminal t2 --for tui-idle|terminal send --terminal t2 --text Read .*dev.md.*a=1, scratchDir=.*\. --enter' "$LOGF")" "3"
try run_clean Codex; check "clean.sh by title and dead tab" "$RC:$OUT" "1:Codex: its tab (t3) does not respond."
check "clean.sh by handle" "$(run_clean t2)" "Dev: context cleaned (/clear) and role resent."
try run_clean planner; check "clean.sh refuses the planner" "$RC:$OUT" "1:Planner: the Planner does not clean itself."
try run_clean cu; check "clean.sh custom without clearCommand" "$RC" "1"; case "$OUT" in *clearCommand*) echo "ok   clean.sh explains clearCommand";; *) echo "FAIL clean.sh: $OUT"; FAIL=1;; esac
try run_clean nobody; check "clean.sh unknown role" "$RC" "1"
check "clean.sh --msg of a worker is its role message" "$(run_clean --msg dev)" "$(cd "$TMP" && KIT="$TMP/home/.orca-roles" worker_msg "$C" dev)"
OUT="$(run_clean --msg planner)"
case "$OUT" in (*"Handles: Dev=t2, Codex=t3, Custom=t4."*"conversation was cleared"*) echo "ok   clean.sh --msg planner: cleared message with the current handles";; (*) echo "FAIL clean.sh --msg planner: $OUT"; FAIL=1;; esac
mkdir -p "$TMP/fakebin-jira"; printf '#!/bin/sh\necho "$*" >> "%s"\n[ "$1 $2" = "worktree show" ] && echo '"'"'{"linkedWorkItem":{"provider":"jira","jiraIdentifier":"ABC-9","url":"https://x.atlassian.net/browse/ABC-9"}}'"'"'\nexit 0\n' "$TMP/orca-jira.log" > "$TMP/fakebin-jira/orca"; chmod +x "$TMP/fakebin-jira/orca"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin-jira:$PATH" ORCA_WORKTREE_ID=w1 ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/clean.sh" --msg planner 2>&1)"
check "clean.sh --msg planner: Jira ticket of this worktree" "$(case "$OUT" in (*"Jira ticket ABC-9 (https://x.atlassian.net/browse/ABC-9)"*) echo jira;; esac) $(grep -c -- '--worktree id:w1' "$TMP/orca-jira.log")" "jira 1"
: > "$LOGF"; try run_clean --all; check "clean.sh --all: dead tab reported" "$RC" "1"; case "$OUT" in *"Codex: its tab (t3) does not respond."*) echo "ok   clean.sh --all: dead tab message";; *) echo "FAIL clean.sh --all: $OUT"; FAIL=1;; esac
check "clean.sh --all excludes the planner" "$(grep -c 'terminal show --terminal t1' "$LOGF" || true)" "0"
check "clean.sh --all goes through the workers" "$(grep -c 'terminal show' "$LOGF")" "3"
check "clean.sh --msg" "$(run_clean --msg dev | sed "s#$TMP/home/.orca-roles#$KIT#g")" "$(cd "$TMP" && worker_msg "$C" dev)"
}

sec_scratch() {
clean_fixture
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
check "common-workers.md: earlier versions in rev-<full sha>, read-only, copy-rev/" "$(grep -c 'rev-\$sha' "$ROOT/prompts/programmer/common-workers.md")$(grep -c 'rev-parse "<commit>^{commit}"' "$ROOT/prompts/programmer/common-workers.md")$(grep -c -- '--short' "$ROOT/prompts/programmer/common-workers.md" || true)$(grep -c 'copy-rev/' "$ROOT/prompts/programmer/common-workers.md")" "1101"
check "planner.md: earlier versions go to the Researcher's scratchDir rev-<full sha>" "$(grep -c 'scratchDir.*rev-<full sha>.*rev-parse "<commit>^{commit}"' "$ROOT/prompts/programmer/planner.md")" "1"
check "tester.md: mutation in place, no copy" "$(grep -c 'in place in the worktree' "$ROOT/prompts/programmer/tester.md")$(grep -c 'rsync' "$ROOT/prompts/programmer/tester.md")" "10"
check "auditor.md: Experiments block uses <scratchDir>/copy/" "$(grep -c '^rsync -a --delete --exclude .git ./ <scratchDir>/copy/' "$ROOT/prompts/programmer/auditor.md")" "1"
}

sec_prompt_rules() {
blk_start
t=$(awk '/^5\. \*\*Check your own tests with mutation/{f=1;print;next} /^[0-9]+\. /{f=0} /^## /{f=0} f' "$ROOT/prompts/programmer/tester.md")
a2=$(grep '^2\. \*\*Baseline' "$ROOT/prompts/programmer/auditor.md" || true)
a7=$(grep '^7\. \*\*Mutation, in place' "$ROOT/prompts/programmer/auditor.md" || true)
a27="$a2$a7"
for k in 'in place in the worktree' 'Recovery first' 'restore any leftover `*.orca-bak`' 'mv <f>.orca-bak <f>' 'cp <f> <f>.orca-bak' 'Baseline.' 'baseline-status.txt' 'baseline.diff' 'do not mutate' 'give no mutation-based verdict' 'One mutant at a time' 'Never use `git checkout`, `git stash` or deleting the backup' 'never have two mutants applied at once' 'only when a specific test fails because of it' 'Verified close' 'equal the baseline' 'say so at once'; do
  printf '%s' "$t" | grep -qF -- "$k" || { echo "FAIL tester.md: the in-place mutation step lost: $k"; FAIL=1; }
done
for k in 'in place in the worktree' 'restore any leftover `*.orca-bak`' 'mv <f>.orca-bak <f>' 'cp <f> <f>.orca-bak' 'Baseline' 'baseline-status.txt' 'baseline.diff' 'baseline-untracked.txt' 'do not mutate' 'give no mutation-based verdict' 'One mutant at a time' 'Never use `git checkout`, `git stash` or deleting the backup' 'never have two applied at once' 'only when a specific test fails because of it' 'equal the baseline' 'say so at once'; do
  printf '%s' "$a27" | grep -qF -- "$k" || { echo "FAIL auditor.md: pass 7 lost: $k"; FAIL=1; }
done
for k in 'baseline-untracked.txt' 'git ls-files -o --exclude-standard' "find . -name '*.orca-bak' -not -path './.git/*'" 'sha1sum' 'do not mutate'; do
  printf '%s' "$t" | grep -qF -- "$k" || { echo "FAIL tester.md: recovery and baseline lost: $k"; FAIL=1; }
  printf '%s' "$a2" | grep -qF -- "$k" || { echo "FAIL auditor.md: pass 2 (recovery and baseline) lost: $k"; FAIL=1; }
done
for k in 'never `cp` over it' 'never chained with `&&`' 'whatever the test result was' 'a chained `mv` would be skipped'; do
  printf '%s' "$t" | grep -qF -- "$k" || { echo "FAIL tester.md: the mutant mechanics lost: $k"; FAIL=1; }
  printf '%s' "$a7" | grep -qF -- "$k" || { echo "FAIL auditor.md: pass 7 mechanics lost: $k"; FAIL=1; }
done
for k in 'look again for leftovers with the `find`' 'untracked hashes'; do
  printf '%s' "$t" | grep -qF -- "$k" || { echo "FAIL tester.md: the verified close lost: $k"; FAIL=1; }
  printf '%s' "$a7" | grep -qF -- "$k" || { echo "FAIL auditor.md: the close in pass 7 lost: $k"; FAIL=1; }
done
printf '%s' "$t" | grep -qF 'the only allowed difference is the tests you deliver' || { echo "FAIL tester.md: the close lost 'the only allowed difference is the tests you deliver'"; FAIL=1; }
printf '%s' "$t$a7" | grep -qF '&& mv' && { echo "FAIL the restore mv is chained with && in the mutation text"; FAIL=1; }
printf '%s' "$a7" | grep -qF 'Relies on the recovery and the baseline of pass 2' || { echo "FAIL auditor.md: pass 7 no longer relies on pass 2 for recovery and baseline"; FAIL=1; }
l2=$(grep -n 'baseline-status.txt' "$ROOT/prompts/programmer/auditor.md" | head -1 | cut -d: -f1 || true)
l3=$(grep -n '^3\. \*\*Criteria before findings' "$ROOT/prompts/programmer/auditor.md" | cut -d: -f1 || true)
{ [ -n "$l2" ] && [ -n "$l3" ] && [ "$l2" -lt "$l3" ]; } || { echo "FAIL auditor.md: the recovery and baseline must come before pass 3 (first baseline-status.txt line [$l2], pass 3 line [$l3])"; FAIL=1; }
printf '%s' "$a2" | grep -qF 'Before any pass that edits files (3 and 7)' || { echo "FAIL auditor.md: pass 2 lost that it precedes every pass that edits files (3 and 7)"; FAIL=1; }
blk_end "tester.md step 5 and auditor.md passes 2 and 7: in-place mutation mechanics pinned"
blk_start
for p in tester auditor; do
  grep -qF 'check that `git status --porcelain`, `git diff` and the untracked hashes' "$ROOT/prompts/programmer/$p.md" || { echo "FAIL $p.md: the closing step lost the *.orca-bak restore and the git status/diff check"; FAIL=1; }
  grep -qF 'git checkout' "$ROOT/prompts/programmer/$p.md" && ! grep -F 'git checkout' "$ROOT/prompts/programmer/$p.md" | grep -qF 'Never use' && { echo "FAIL $p.md: mentions git checkout without forbidding it"; FAIL=1; }
  grep -iE 'mutat[a-z]* .*in (a|your|the) copy|copy .*mutat' "$ROOT/prompts/programmer/$p.md" | grep -v 'in place' && { echo "FAIL $p.md: still tells to mutate in a copy"; FAIL=1; }
done
grep -qF 'in your copy' "$ROOT/prompts/programmer/auditor.md" && { echo "FAIL auditor.md: still says 'in your copy' (breaking a criterion is mutation, in place)"; FAIL=1; }
p3=$(grep '^3\. \*\*Criteria before findings' "$ROOT/prompts/programmer/auditor.md" || true)
for k in '**breaking it** in place' 'mechanics of pass 7' 'backup with `cp`' 'one change at a time' 'restore with `mv`'; do
  printf '%s' "$p3" | grep -qF -- "$k" || { echo "FAIL auditor.md: pass 3 lost: $k"; FAIL=1; }
done
rr=$(grep -F '| **Auditor** |' "$ROOT/README.md" || true)
printf '%s' "$rr" | grep -qF 'in place' || { echo "FAIL README.md: the Auditor row does not say mutation is in place"; FAIL=1; }
printf '%s' "$rr" | grep -qiF 'copy' && { echo "FAIL README.md: the Auditor row still mentions a copy"; FAIL=1; }
blk_end "tester.md and auditor.md: close step, git checkout forbidden, no mutation in a copy"
blk_start
v=$(grep '^- The reviewer verifies, it does not change' "$ROOT/prompts/programmer/auditor.md" || true)
for k in 'only files of the worktree you may modify are those you mutate, temporarily' 'mechanics of pass 7' 'proving at the end with `git diff`' 'Never edit Dev'"'"'s or the Tester'"'"'s files in any other way' 'goes in your scratch folder'; do
  printf '%s' "$v" | grep -qF -- "$k" || { echo "FAIL auditor.md: the reviewer-verifies rule lost: $k"; FAIL=1; }
done
grep -qF 'Mutation is done in place (pass 7). Every other pass that edits files' "$ROOT/prompts/programmer/auditor.md" || { echo "FAIL auditor.md: Experiments no longer says mutation is in place and the rest goes in a copy"; FAIL=1; }
blk_end "auditor.md: reviewer modifies only to mutate, Experiments consistent with pass 7"
blk_start
o=$(grep '^- \*\*One step at a time\.\*\*' "$ROOT/prompts/programmer/planner.md" || true)
for k in 'Only one code task is in flight at any moment' 'Dev, Tester or Auditor' 'dispatch no other task to any worker in that worktree' 'mutate the tree in place' 'Never start the next step'"'"'s Dev task while the current step is open'; do
  printf '%s' "$o" | grep -qF -- "$k" || { echo "FAIL planner.md: One step at a time lost: $k"; FAIL=1; }
done
for k in 'the Deployer'"'"'s guide and a Researcher measurement wait until the code task reports' 'The one exception: when the in-flight Tester or Auditor itself asks for services, dispatch the Deployer to start or stop them (it edits no code), as part of that task; nothing else is dispatched until the code task reports.'; do
  printf '%s' "$o" | grep -qF -- "$k" || { echo "FAIL planner.md: One step at a time lost: $k"; FAIL=1; }
done
check "planner.md: One step at a time has exactly one exception" "$(printf '%s' "$o" | grep -o 'exception' | wc -l | tr -d ' ')" "1"
check "planner.md: One step at a time names the Deployer only for the guide and the exception" "$(printf '%s' "$o" | grep -o 'Deployer' | wc -l | tr -d ' ')" "2"
check "planner.md: One step at a time names the Researcher only as waiting" "$(printf '%s' "$o" | grep -o 'Researcher' | wc -l | tr -d ' ')" "1"
grep -qF 'ask the Planner before you start mutating (the Deployer, who edits no code, starts and stops them as part of your task)' "$ROOT/prompts/programmer/tester.md" || { echo "FAIL tester.md: the Services rule lost that the Deployer starts and stops services for the Tester"; FAIL=1; }
grep -qF 'ask the Planner: the Deployer, who edits no code, starts and stops them as part of your task' "$ROOT/prompts/programmer/auditor.md" || { echo "FAIL auditor.md: the Limits lost that the Deployer starts and stops services for the Auditor"; FAIL=1; }
blk_end "planner.md: one exception (the Deployer's services for the in-flight Tester or Auditor), guide and Researcher wait"
blk_start
for p in common-workers planner; do
  case $p in planner) pre='^- Everything you draft for outside the worktree';; *) pre='^- Commit messages follow the repository';; esac
  cr=$(grep "$pre" "$ROOT/prompts/programmer/$p.md" || true)
  printf '%s' "$cr" | grep -qF ') (' && { echo "FAIL $p.md: the commit rule has a double parenthesis"; FAIL=1; }
  printf '%s' "$cr" | grep -qF 'ticket key) and the depth of its body' || { echo "FAIL $p.md: the commit rule lost 'ticket key) and the depth of its body'"; FAIL=1; }
  printf '%s' "$cr" | grep -qF 'what is left out. GitHub'"'"'s own merge subjects (' || { echo "FAIL $p.md: the GitHub merge-subject warning must be its own sentence"; FAIL=1; }
  printf '%s' "$cr" | grep -qF 'your subjects never carry a handle. A subject-only commit is not acceptable' || { echo "FAIL $p.md: the commit rule lost its closing sentences"; FAIL=1; }
done
blk_end "commit rule: no double parenthesis, merge-subject warning in its own sentence"
check "no prompt tells an agent to delete or use /tmp" "$(grep -rnE '\brm\b|mktemp|/tmp|/var/folders' "$ROOT/prompts/" | wc -l | tr -d ' ')" "0"
}

sec_cleanup_msg() {
clean_fixture
rm -rf "$KIT/tmp"
rm -f "$TMP/fakebin/orca"
M3="$(planner_msg "$C" "planner dev" "$TMP/state.env" "" "" 0)"
case "$M3" in *"propose to the user cleaning the workers' context"*) echo "ok   planner_msg: cleanup when closing a step";; *) echo "FAIL planner_msg cleanup: $M3"; FAIL=1;; esac
}

sec_mcp() {
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
fake_bash
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
}

sec_mcp_placeholders() {
fake_bash
# mcpServers placeholders, project name and browser state
write_placeholders_config
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
for sec in '^## Your browser' 'browser-login.sh' 'browser_evaluate'; do grep -q "$sec" "$ROOT/prompts/programmer/e2e-tester.md" || { echo "FAIL e2e-tester.md without $sec"; FAIL=1; }; done
grep -q 'browser-login.sh' "$ROOT/prompts/programmer/planner.md" || { echo "FAIL planner.md without browser-login"; FAIL=1; }
grep -q 'orca-<service>.pid' "$ROOT/prompts/programmer/deployer.md" || { echo "FAIL deployer.md without services"; FAIL=1; }
echo "ok   E2E test prompts"
}

sec_custom_command() {
# agent.sh custom: placeholders and extraArgs (bash is replaced by an echo)
cat > "$KIT/config.json" <<J
{ "defaults": {}, "mcpServers": {}, "roles": { "x": { "agent": "custom", "command": "run --m {model} --p {prompts} --f {prompt}", "model": "a b", "extraArgs": ["--k", "v w"] } } }
J
fake_bash
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$KIT/bin/agent.sh" x)"
check "custom: command with placeholders and extraArgs" "$OUT" "run --m a\\ b --p $TMP/home/.orca-roles/prompts --f $TMP/home/.orca-roles/prompts/programmer/x.md --k v\\ w"
}

sec_jira_key() {
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
}

sec_composer_title() {
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
}

sec_project_config() {
# An uncommitted .orca-roles.json in the main checkout also applies to its worktrees
MAIN="$TMP/main"; mkdir -p "$MAIN"; git -C "$MAIN" init -q
git -C "$MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$TMP/wt" -b wt-branch 2>/dev/null
echo '{ "settings": { "jiraHandoff": false } }' > "$MAIN/.orca-roles.json"
check "project config from the main checkout" "$(merged_config "$TMP/wt" | jq -r '.settings.jiraHandoff')" "false"
echo '{ "settings": { "jiraHandoff": true } }' > "$TMP/wt/.orca-roles.json"
check "project config: the worktree's wins" "$(merged_config "$TMP/wt" | jq -r '.settings.jiraHandoff')" "true"
}

sec_mcp_gitdir() {
write_placeholders_config; C="$KIT/config.json"; fake_bash
OUT="$(cd "$PROJ" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/agent.sh" vt 2>&1)"; F="${OUT#run }"
# MCP file in the worktree's git dir (temporary files do not pile up)
check "agent.sh: MCP file in the git dir" "$F" "$(cd "$PROJ/.git" && pwd)/orca-roles-mcp-vt.json"
}

sec_empty_lists() {
# Empty lists (macOS bash 3.2 fails with an empty "${A[@]}" and set -u)
cat > "$KIT/config.json" <<'J'
{ "defaults": {}, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "cx": { "agent": "codex", "mcp": "all" } } }
J
printf '#!/bin/sh\necho "codex:$#"\n' > "$TMP/fakebin/codex"; chmod +x "$TMP/fakebin/codex"
check "agent.sh codex without options: only --add-dir <scratch>, the trust -c and the anchor -c" "$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$KIT/bin/agent.sh" cx 2>&1)" "codex:6"
printf 'PLANNER=t1\n' > "$TMP/state.env"
check "clean.sh --all without workers" "$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$KIT/config.json" "$KIT/bin/clean.sh" --all 2>&1)" "There are no workers to clean in this workspace."
}

sec_cli_shim() {
cli_shim_dir
# Orca CLI under another name (WSL: ORCA_CLI_COMMAND=orca-ide): 'orca' wrapper in $KIT/shim
check "shim: 'orca' calls ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide bash -c '. "$KIT/bin/lib.sh"; orca terminal list')" "orca-ide:terminal list"
rm -f "$KIT/shim/orca"
check "shim: not created without ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND='' bash -c '. "$KIT/bin/lib.sh"; command -v orca || echo none')" "none"
check "shim: not created if 'orca' already exists" "$(PATH="$TMP/fakebin:$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide bash -c 'printf "#!/bin/sh\n" > "$0/orca"; chmod +x "$0/orca"; . "$KIT/bin/lib.sh"; command -v orca' "$TMP/fakebin")" "$TMP/fakebin/orca"
rm -f "$TMP/fakebin/orca"
}

sec_roles_yaml() {
# roles-yaml: local orca.yaml, ignored and listed in .worktreeinclude, nothing to commit
Y="$TMP/ymain"; mkdir -p "$Y"; git -C "$Y" init -q; git -C "$Y" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$Y" worktree add -q "$TMP/ywt" -b ybranch 2>/dev/null
mkdir -p "$TMP/yoff"; printf '#!/bin/sh\nexit 1\n' > "$TMP/yoff/orca"; chmod +x "$TMP/yoff/orca"
yaml() { (cd "$1" && shift && PATH="$TMP/yoff:$PATH" "$ROOT/bin/orca-yaml.sh" "$@" 2>&1); }
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

# roles-yaml: checks Orca's setup policy through a fake 'orca'
YF="$TMP/yfake"; mkdir -p "$YF"; printf '#!/bin/sh\ncat "$FAKE_JSON"\n' > "$YF/orca"; chmod +x "$YF/orca"
ypol() { printf '{"ok":true,"result":{"repo":{"hookSettings":%s}}}' "$1" > "$TMP/yp.json"; rm -f "$Y/orca.yaml" "$Y/.worktreeinclude"; : > "$Y/.git/info/exclude"
  try env PATH="$YF:$PATH" FAKE_JSON="$TMP/yp.json" bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" 2>&1' "$Y" "$ROOT"; }
git -C "$Y" rm -q -f orca.yaml; git -C "$Y" -c user.name=t -c user.email=t@t commit -q -m rm-yaml
ypol '{"scripts":{"setup":"npm i"}}'; check "roles-yaml: local-only without the kit stops and writes nothing" "$RC:$(ls -A "$Y" | tr '\n' ' ')" "1:.git "
ypol '{"scripts":{"setup":"# $HOME/.orca-roles/bin/launch.sh"}}'; check "roles-yaml: a commented launch.sh does not count" "$RC" "1"
ypol '{"scripts":{"setup":"$HOME/.orca-roles/bin/launch.sh"}}'; check "roles-yaml: local already launches the kit" "$RC:$(ls -A "$Y" | tr '\n' ' ')" "0:.git "
ypol '{"commandSourcePolicy":"run-both","scripts":{"setup":"npm i"}}'; check "roles-yaml: run-both without the kit proceeds" "$RC:$(ls "$Y" | tr '\n' ' ')" "0:orca.yaml "
ypol '{"commandSourcePolicy":null,"scripts":{"setup":"npm i"}}'; check "roles-yaml: null policy is shared-only" "$RC" "0"
ypol '{"setupRunPolicy":"ask"}'; case "$OUT" in *WARNING*) echo "ok   roles-yaml warns on setupRunPolicy ask";; *) echo "FAIL roles-yaml ask: $OUT"; FAIL=1;; esac
ypol '{}'; case "$OUT" in *WARNING*|*"could not"*) echo "FAIL roles-yaml run-by-default is not silent: $OUT"; FAIL=1;; *) echo "ok   roles-yaml run-by-default is silent";; esac
printf 'x' > "$TMP/yp.json"; rm -f "$Y/orca.yaml"; try env PATH="$YF:$PATH" FAKE_JSON="$TMP/yp.json" bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" 2>&1' "$Y" "$ROOT"
check "roles-yaml: unreadable Orca answer still proceeds" "$RC" "0"; case "$OUT" in *"could not check"*) echo "ok   roles-yaml says it could not check";; *) echo "FAIL roles-yaml: $OUT"; FAIL=1;; esac

# roles-yaml and the setup source policy: a fake 'orca' on a PATH without the real one, its own repo
Y2="$TMP/ypol"; mkdir -p "$Y2"; git -C "$Y2" init -q; git -C "$Y2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
FB="$TMP/yfake2"; mkdir -p "$FB"
cat > "$FB/orca" <<'FEOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
case "$1 $2 $3 $4" in
  "repo show --repo path:"*) cat "$FAKE_PATH" 2>/dev/null; exit "${FAKE_PATH_RC:-0}";;
  "worktree show --worktree current") cat "$FAKE_WT" 2>/dev/null; exit "${FAKE_WT_RC:-0}";;
  "repo show --repo id:"*) cat "$FAKE_ID" 2>/dev/null; exit "${FAKE_ID_RC:-0}";;
esac
exit 1
FEOF
chmod +x "$FB/orca"
YLOG="$TMP/y2.log"; YP="$TMP/y2-path.json"; YW="$TMP/y2-wt.json"; YI="$TMP/y2-id.json"
hsjson() { jq -nc --arg p "$1" --arg l "$2" --arg r "${3:-}" '{ok:true,result:{repo:{hookSettings:({scripts:{setup:$l}}
  + (if $p == "MISSING" then {} elif $p == "null" then {commandSourcePolicy: null} else {commandSourcePolicy: $p} end)
  + (if $r == "" then {} else {setupRunPolicy: $r} end))}}}'; }
yreset() { rm -f "$Y2/orca.yaml" "$Y2/.worktreeinclude" "$YLOG" "$YP" "$YW" "$YI"; : > "$Y2/.git/info/exclude"; }
yrun() { try env -u ORCA_CLI_COMMAND PATH="$FB:/usr/bin:/bin" FAKE_LOG="$YLOG" FAKE_PATH="$YP" FAKE_WT="$YW" FAKE_ID="$YI" FAKE_PATH_RC="${FAKE_PATH_RC:-0}" FAKE_WT_RC="${FAKE_WT_RC:-0}" FAKE_ID_RC="${FAKE_ID_RC:-0}" \
  bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" "${@:2}" 2>&1' "$Y2" "$ROOT" "$@"; }
yclass() { local f; f="$(LC_ALL=C ls -A "$Y2" | tr '\n' ' ')"
  if [ "$RC" = 1 ] && [ "$f" = ".git " ] && [[ "$OUT" == *"Nothing was written"* ]]; then echo a
  elif [ "$RC" = 0 ] && [ "$f" = ".git " ] && [[ "$OUT" == *"not needed"* ]]; then echo b
  elif [ "$RC" = 0 ] && [ "$f" = ".git .worktreeinclude orca.yaml " ]; then echo c
  else echo "?$RC:$f"; fi; }
KITL='$HOME/.orca-roles/bin/launch.sh'
yfor() { yreset; hsjson "$1" "$2" "${3:-}" > "$YP"; yrun; }

# roles-yaml: every policy against every local script gives the right outcome (error, not needed, or written)
M=""; for p in MISSING null bogus local-only run-both shared-only; do
  for li in 0 1 2 3 4; do
    case $li in 0) l="";; 1) l=$' \n\t ';; 2) l="npm install";; 3) l="$KITL";; 4) l=$'npm install\n'"$KITL";; esac
    yfor "$p" "$l"; M="$M$p/$li=$(yclass) "
  done; done
check "roles-yaml policy x local matrix" "$M" "MISSING/0=c MISSING/1=c MISSING/2=a MISSING/3=b MISSING/4=b null/0=c null/1=c null/2=c null/3=c null/4=c bogus/0=c bogus/1=c bogus/2=c bogus/3=c bogus/4=c local-only/0=a local-only/1=a local-only/2=a local-only/3=b local-only/4=b run-both/0=c run-both/1=c run-both/2=c run-both/3=b run-both/4=b shared-only/0=c shared-only/1=c shared-only/2=c shared-only/3=c shared-only/4=c "

# roles-yaml: when it writes nothing, the project is byte-identical (git status, exclude, an existing .worktreeinclude)
for l in "npm install" "$KITL"; do
  yreset; printf 'foo\n' > "$Y2/.git/info/exclude"; printf 'keep\n' > "$Y2/.worktreeinclude"; hsjson local-only "$l" > "$YP"
  S1="$(git -C "$Y2" status --porcelain --ignored; shasum "$Y2/.git/info/exclude" "$Y2/.worktreeinclude")"; yrun
  check "roles-yaml writes nothing when local-only ($l): rc, files" "$RC:$([ -e "$Y2/orca.yaml" ] && echo yaml || echo none)" "$([ "$l" = "$KITL" ] && echo 0 || echo 1):none"
  check "roles-yaml writes nothing when local-only ($l): bytes" "$(git -C "$Y2" status --porcelain --ignored; shasum "$Y2/.git/info/exclude" "$Y2/.worktreeinclude")" "$S1"
done
yreset; hsjson local-only "npm i" > "$YP"; yrun; check "roles-yaml error offers both fixes" "$(printf '%s' "$OUT" | grep -c -E '^  [12]\. ')" "2"
yreset; hsjson local-only "npm i" > "$YP"; yrun; check "roles-yaml error goes to stderr, not stdout" "$(env -u ORCA_CLI_COMMAND PATH="$FB:/usr/bin:/bin" FAKE_LOG="$YLOG" FAKE_PATH="$YP" bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" 2>/dev/null' "$Y2" "$ROOT" | wc -c | tr -d ' ')" "0"

# roles-yaml: which local script lines count as launching the kit
# shellcheck disable=SC2088
POS=( '$HOME/.orca-roles/bin/launch.sh' '${HOME}/.orca-roles/bin/launch.sh' '~/.orca-roles/bin/launch.sh' '/Users/x/.orca-roles/bin/launch.sh'
  '"$HOME/.orca-roles/bin/launch.sh"' "'\$HOME/.orca-roles/bin/launch.sh'" '$HOME/.orca-roles/bin/launch.sh --disable e2e-tester' '  $HOME/.orca-roles/bin/launch.sh' )
NEG=( '# $HOME/.orca-roles/bin/launch.sh' '   # $HOME/.orca-roles/bin/launch.sh' 'echo $HOME/.orca-roles/bin/launch.sh' 'roles' '/x/other-launch.sh'
  '$HOME/.orca-roles/bin/launch.sh.bak' '$HOME/.orca-roles/bin/other.sh' )
M=""; for l in "${POS[@]}"; do yfor local-only "$l"; M="$M$(yclass)"; done
check "roles-yaml kit detection: forms that count" "$M" "bbbbbbbb"
M=""; for l in "${NEG[@]}"; do yfor local-only "$l"; M="$M$(yclass)"; done
check "roles-yaml kit detection: forms that do not count" "$M" "aaaaaaa"
yfor local-only $'# note\n   # $HOME/.orca-roles/bin/launch.sh\nnpm i'; M="$(yclass)"; yfor local-only $'# note\nnpm i\n$HOME/.orca-roles/bin/launch.sh'; check "roles-yaml kit detection: comment vs real line" "$M$(yclass)" "ab"

# roles-yaml: setupRunPolicy warnings, alone and with each outcome
M=""; for r in "" run-by-default ask skip-by-default; do
  for pl in "local-only|npm i" "local-only|$KITL" "shared-only|npm i"; do
    yfor "${pl%%|*}" "${pl#*|}" "$r"; w=0; [[ "$OUT" == *WARNING* ]] && w=1; M="$M${r:-none}/${pl%%|*}:$(yclass):w$w "
  done; done
check "roles-yaml setupRunPolicy warnings" "$M" "none/local-only:a:w0 none/local-only:b:w0 none/shared-only:c:w0 run-by-default/local-only:a:w0 run-by-default/local-only:b:w0 run-by-default/shared-only:c:w0 ask/local-only:a:w1 ask/local-only:b:w1 ask/shared-only:c:w1 skip-by-default/local-only:a:w1 skip-by-default/local-only:b:w1 skip-by-default/shared-only:c:w1 "
yfor shared-only "npm i" ask; check "roles-yaml silent about the lookup when it worked" "$([[ "$OUT" == *"could not check"* ]] && echo note || echo quiet)" "quiet"

# roles-yaml: how the repo is looked up and what happens when it fails (generic note, proceeds)
OKJ="$(hsjson local-only "npm i")"; MISS='{"ok":false,"error":{"code":"repo_not_found","message":"repo_not_found"}}'
NOTRUN='{"ok":false,"error":{"code":"runtime_unavailable","message":"x"}}'; WTJ='{"ok":true,"result":{"worktree":{"repoId":"r123"}}}'
yreset; printf '%s' "$OKJ" > "$YP"; yrun; check "roles-yaml lookup: path hit uses one call" "$(yclass):$(wc -l < "$YLOG" | tr -d ' ')" "a:1"
yreset; printf '%s' "$MISS" > "$YP"; printf '%s' "$WTJ" > "$YW"; printf '%s' "$OKJ" > "$YI"; FAKE_PATH_RC=1 yrun
check "roles-yaml lookup: path miss falls back to the repo id" "$(yclass):$(sed -n 3p "$YLOG")" "a:repo show --repo id:r123 --json"
yreset; printf '%s' "$MISS" > "$YP"; printf '%s' "$WTJ" > "$YW"; printf '%s' "$MISS" > "$YI"; FAKE_PATH_RC=1 FAKE_ID_RC=1 yrun
check "roles-yaml lookup: id miss too proceeds with a note" "$(yclass):$([[ "$OUT" == *"could not check"* ]] && echo note)" "c:note"
yreset; printf '%s' "$MISS" > "$YP"; printf '%s' '{"ok":false,"error":{"code":"selector_not_found"}}' > "$YW"; FAKE_PATH_RC=1 FAKE_WT_RC=1 yrun
check "roles-yaml lookup: not registered proceeds with a note" "$(yclass):$([[ "$OUT" == *"could not check Orca's setup policy (project not registered"* ]] && echo note)" "c:note"
yreset; printf '%s' "$NOTRUN" > "$YP"; FAKE_PATH_RC=1 yrun
check "roles-yaml lookup: runtime_unavailable proceeds, no fallback" "$(yclass):$([[ "$OUT" == *"could not check Orca's setup policy (Orca is not running)"* ]] && echo note):$(wc -l < "$YLOG" | tr -d ' ')" "c:note:1"
yreset; printf '%s' "$MISS" > "$YP"; printf '%s' "$NOTRUN" > "$YW"; FAKE_PATH_RC=1 FAKE_WT_RC=1 yrun
check "roles-yaml lookup: runtime_unavailable on the fallback" "$(yclass):$([[ "$OUT" == *"(Orca is not running)"* ]] && echo note)" "c:note"
yreset; printf 'not json at all' > "$YP"; printf 'nope' > "$YW"; yrun
check "roles-yaml lookup: non-JSON answers proceed with a note" "$(yclass):$([[ "$OUT" == *"could not check"* ]] && echo note)" "c:note"
if ! PATH=/usr/bin:/bin command -v orca >/dev/null 2>&1; then
  yreset; try env -u ORCA_CLI_COMMAND PATH=/usr/bin:/bin bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" 2>&1' "$Y2" "$ROOT"
  check "roles-yaml lookup: no orca on PATH proceeds with a note" "$(yclass):$([[ "$OUT" == *"could not check Orca's setup policy (Orca CLI not found)"* ]] && echo note)" "c:note"
fi

# roles-yaml --remove does not consult the policy
yreset; hsjson shared-only "x" > "$YP"; yrun; hsjson local-only "npm i" > "$YP"; rm -f "$YLOG"; yrun --remove
check "roles-yaml --remove ignores the policy" "$RC:$(LC_ALL=C ls -A "$Y2" | tr '\n' ' '):$([ -e "$YLOG" ] && echo asked || echo not-asked)" "0:.git :not-asked"

# roles-yaml: kit detection in chained commands, the $ORCA_CLI_COMMAND route, guards and messages
POS2=( '$HOME/.orca-roles/bin/launch.sh;' 'npm i && $HOME/.orca-roles/bin/launch.sh' 'npm i; $HOME/.orca-roles/bin/launch.sh' 'false || $HOME/.orca-roles/bin/launch.sh'
  '"/Users/John Doe/.orca-roles/bin/launch.sh"' 'bash -l $HOME/.orca-roles/bin/launch.sh' 'bash $HOME/.orca-roles/bin/launch.sh' 'exec $HOME/.orca-roles/bin/launch.sh'
  'source $HOME/.orca-roles/bin/launch.sh' '. $HOME/.orca-roles/bin/launch.sh' 'echo hi; $HOME/.orca-roles/bin/launch.sh --disable e2e-tester' 'echo hi && $HOME/.orca-roles/bin/launch.sh' )
NEG2=( '# $HOME/.orca-roles/bin/launch.sh' '   # $HOME/.orca-roles/bin/launch.sh' 'npm i # $HOME/.orca-roles/bin/launch.sh' 'echo $HOME/.orca-roles/bin/launch.sh'
  'printf %s $HOME/.orca-roles/bin/launch.sh' 'echo $HOME/.orca-roles/bin/launch.sh && npm i' '/x/other-launch.sh' '$HOME/.orca-roles/bin/launch.sh.bak' 'roles'  'npm i && echo $HOME/.orca-roles/bin/launch.sh' )
M=""; for l in "${POS2[@]}"; do yfor local-only "$l"; M="$M$(yclass)"; done
check "roles-yaml kit detection: chained, quoted and wrapped forms count" "$M" "bbbbbbbbbbbb"
M=""; for l in "${NEG2[@]}"; do yfor local-only "$l"; M="$M$(yclass)"; done
check "roles-yaml kit detection: comments, echo/printf and look-alikes do not count" "$M" "aaaaaaaaaa"
M=""; for l in "${POS2[@]}"; do yfor run-both "$l"; M="$M$(yclass)"; done
check "roles-yaml kit detection: same forms under run-both write nothing" "$M" "bbbbbbbbbbbb"

# roles-yaml: the $ORCA_CLI_COMMAND route (the only one on WSL) when there is no 'orca' on PATH
FB2="$TMP/yfake3"; mkdir -p "$FB2"; cp "$FB/orca" "$FB2/orca-ide"
yrun2() { try env PATH="$FB2:/usr/bin:/bin" ORCA_CLI_COMMAND="$1" FAKE_LOG="$YLOG" FAKE_PATH="$YP" FAKE_WT="$YW" FAKE_ID="$YI" \
  bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" 2>&1' "$Y2" "$ROOT"; }
if ! PATH=/usr/bin:/bin command -v orca >/dev/null 2>&1; then
  yreset; hsjson local-only "npm i" > "$YP"; yrun2 orca-ide
  check "roles-yaml uses \$ORCA_CLI_COMMAND when there is no orca on PATH" "$(yclass):$(sed -n 1p "$YLOG")" "a:repo show --repo path:$Y2 --json"
  yreset; hsjson local-only "npm i" > "$YP"; yrun2 no-such-orca
  check "roles-yaml: \$ORCA_CLI_COMMAND that does not exist is a generic note" "$(yclass):$([[ "$OUT" == *"could not check Orca's setup policy (Orca CLI not found)"* ]] && echo note):$([ -e "$YLOG" ] && echo called || echo none)" "c:note:none"
fi

# roles-yaml: the final note only when unchecked, jq missing, hookSettings of the wrong shape
yfor shared-only "npm i"; M="$([[ "$OUT" == *"what runs depends"* ]] && echo note || echo quiet)"
yreset; printf 'x' > "$YP"; yrun; check "roles-yaml final note: only when the policy was not checked" "$M:$([[ "$OUT" == *"what runs depends"* ]] && echo note || echo quiet)" "quiet:note"
NJ="$TMP/ynojq"; mkdir -p "$NJ"; for t in bash git grep mktemp dirname basename cat rm touch mkdir; do ln -sf "$(command -v $t)" "$NJ/$t"; done
yreset; hsjson local-only "npm i" > "$YP"; try env -u ORCA_CLI_COMMAND PATH="$FB:$NJ" FAKE_LOG="$YLOG" FAKE_PATH="$YP" bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" 2>&1' "$Y2" "$ROOT"
check "roles-yaml without jq: says so and proceeds" "$(yclass):$([[ "$OUT" == *"(jq not found)"* ]] && echo note)" "c:note"
yreset; printf '%s' '{"ok":true,"result":{"repo":{"hookSettings":"oops"}}}' > "$YP"; yrun
check "roles-yaml unusable hookSettings: note and final note, proceeds" "$(yclass):$([[ "$OUT" == *"(unexpected response from Orca)"* ]] && echo note):$([[ "$OUT" == *"what runs depends"* ]] && echo final)" "c:note:final"
yfor local-only "npm i" ask; check "roles-yaml ask warning text" "$([[ "$OUT" == *"policy is 'ask'"* && "$OUT" == *"--setup run"* ]] && echo ok)" "ok"
yfor shared-only "npm i" skip-by-default; check "roles-yaml skip-by-default warning text" "$([[ "$OUT" == *"policy is 'skip-by-default'"* && "$OUT" == *"will not start by itself"* ]] && echo ok)" "ok"

# roles-yaml: run-both with the kit in the local script and an orca.yaml created earlier says the kit runs twice and how to fix it
yfor shared-only "npm i"; hsjson run-both "$KITL" > "$YP"; S2="$(shasum "$Y2/orca.yaml" "$Y2/.worktreeinclude")"; yrun
check "roles-yaml run-both + kit + our orca.yaml: running twice, with the fix" "$RC:$([[ "$OUT" == *"is running TWICE"* || "$OUT" == *"running TWICE"* ]] && echo twice):$([[ "$OUT" == *"roles-yaml --remove"* ]] && echo hint):$([ "$(shasum "$Y2/orca.yaml" "$Y2/.worktreeinclude")" = "$S2" ] && echo same)" "0:twice:hint:same"
yfor run-both "$KITL"; check "roles-yaml run-both + kit without our orca.yaml: would run twice, no TWICE" "$([[ "$OUT" == *"would make the kit run twice"* ]] && echo would):$([[ "$OUT" == *TWICE* ]] && echo twice || echo no)" "would:no"
yfor shared-only "npm i"; hsjson local-only "$KITL" > "$YP"; yrun
check "roles-yaml local-only + kit + our orca.yaml: not needed, no TWICE" "$RC:$([[ "$OUT" == *"not needed"* ]] && echo ok):$([[ "$OUT" == *TWICE* ]] && echo twice || echo no)" "0:ok:no"

# roles-yaml: the error text does not say that saving a script sets local-only
yfor local-only "npm i"; check "roles-yaml error text: no claim that saving sets local-only" "$([[ "$OUT" == *"Saving anything"* || "$OUT" == *"sets the source to local-only"* ]] && echo claim || echo none)" "none"

# roles-yaml --check: read-only, silent when Orca cannot be asked, one WARNING line otherwise
KIT_Y="scripts:"$'\n'"  setup: |"$'\n'"    \$HOME/.orca-roles/bin/launch.sh"$'\n'
ychk() { yreset; hsjson "$1" "$2" "${3:-}" > "$YP"; [ -z "${4:-}" ] || printf '%s' "$4" > "$Y2/orca.yaml"; [ -z "${5:-}" ] || { printf '%s\n' "$5" > "$Y2/.worktreeinclude"; echo orca.yaml > "$Y2/.git/info/exclude"; }; yrun --check; }
W_PRE="WARNING: new worktrees of this project will not start the kit: "
W_LOCAL="${W_PRE}Orca's setup source is local-only and the local setup script does not run launch.sh. Put \$HOME/.orca-roles/bin/launch.sh as the first line of that script (Settings → Repository → ypol → Setup script), or switch the setup source to \"run both\" and run roles-yaml."
W_SHARED="${W_PRE}Orca's setup source is shared-only and no orca.yaml that reaches new worktrees runs launch.sh. Run roles-yaml, or add \$HOME/.orca-roles/bin/launch.sh to the committed orca.yaml's setup script."
W_BOTH0="${W_PRE}neither the local setup script nor an orca.yaml that reaches new worktrees runs launch.sh. Run roles-yaml, or put \$HOME/.orca-roles/bin/launch.sh in the local setup script (Settings → Repository → ypol → Setup script)."
W_TWICE="WARNING: new worktrees of this project start the kit twice: both the local setup script and orca.yaml run launch.sh. Fix it with roles-yaml --remove, or drop launch.sh from the local setup script."
W_ASK="WARNING: this project's setup policy is 'ask': Orca asks each time, and 'orca worktree create' needs '--setup run'. The kit does not start by itself."
W_SKIP="WARNING: this project's setup policy is 'skip-by-default': setup does not run automatically, so the kit will not start by itself."
ychk local-only "$KITL"; check "roles-yaml --check: local-only with the kit is silent" "$RC:$OUT" "0:"
ychk shared-only "npm i" "" "$KIT_Y" orca.yaml; check "roles-yaml --check: shared-only, orca.yaml listed in .worktreeinclude is silent" "$RC:$OUT" "0:"
ychk run-both "$KITL"; check "roles-yaml --check: run-both with only the local script is silent" "$RC:$OUT" "0:"
ychk run-both "npm i" "" "$KIT_Y" orca.yaml; check "roles-yaml --check: run-both with only orca.yaml is silent" "$RC:$OUT" "0:"
yreset; try env -u ORCA_CLI_COMMAND PATH=/usr/bin:/bin bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" --check 2>&1' "$Y2" "$ROOT"
if ! PATH=/usr/bin:/bin command -v orca >/dev/null 2>&1; then check "roles-yaml --check: Orca CLI missing is silent" "$RC:$OUT" "0:"; fi
yreset; printf '%s' "$NOTRUN" > "$YP"; FAKE_PATH_RC=1 yrun --check; check "roles-yaml --check: Orca not running is silent" "$RC:$OUT" "0:"
ychk local-only "npm i"; check "roles-yaml --check: local-only without the kit warns" "$RC:$OUT" "0:$W_LOCAL"
ychk shared-only "npm i"; check "roles-yaml --check: shared-only without orca.yaml warns" "$RC:$OUT" "0:$W_SHARED"
ychk shared-only "npm i" "" "$KIT_Y"; check "roles-yaml --check: shared-only, orca.yaml neither tracked nor included warns" "$RC:$OUT" "0:$W_SHARED"
ychk shared-only "npm i" "" "# \$HOME/.orca-roles/bin/launch.sh"$'\n' orca.yaml; check "roles-yaml --check: shared-only, commented launch.sh warns" "$RC:$OUT" "0:$W_SHARED"
ychk run-both "npm i"; check "roles-yaml --check: run-both with neither warns" "$RC:$OUT" "0:$W_BOTH0"
ychk run-both "$KITL" "" "$KIT_Y" orca.yaml; check "roles-yaml --check: run-both with both warns about twice" "$RC:$OUT" "0:$W_TWICE"
ychk local-only "$KITL" ask; check "roles-yaml --check: ask message" "$RC:$OUT" "0:$W_ASK"
ychk local-only "$KITL" skip-by-default; check "roles-yaml --check: skip-by-default message" "$RC:$OUT" "0:$W_SKIP"
ychk shared-only "npm i" ask "$KIT_Y" orca.yaml; check "roles-yaml --check: ask with a working orca.yaml" "$RC:$OUT" "0:$W_ASK"
ychk shared-only "npm i" "" "$KIT_Y" orca.yaml; check "roles-yaml --check: listed and ignored orca.yaml is silent" "$RC:$OUT" "0:"
yreset; hsjson shared-only "npm i" > "$YP"; printf '%s' "$KIT_Y" > "$Y2/orca.yaml"; printf 'orca.yaml\n' > "$Y2/.worktreeinclude"; yrun --check
check "roles-yaml --check: listed but not ignored orca.yaml warns" "$RC:$OUT" "0:$W_SHARED"
rm -f "$Y2/.worktreeinclude"
for l in 'setup: npm i # $HOME/.orca-roles/bin/launch.sh' 'setup: |\n    echo run $HOME/.orca-roles/bin/launch.sh later'; do
  yreset; hsjson shared-only "npm i" > "$YP"; printf 'scripts:\n  %b\n' "$l" > "$Y2/orca.yaml"; git -C "$Y2" add -f orca.yaml; yrun --check
  check "roles-yaml --check: tracked orca.yaml with launch.sh only in a comment/echo warns ($l)" "$RC:$OUT" "0:$W_SHARED"
  git -C "$Y2" rm -q -f --cached orca.yaml
done
yreset; hsjson shared-only "npm i" > "$YP"; printf 'scripts:\n  setup: npm i && $HOME/.orca-roles/bin/launch.sh\n' > "$Y2/orca.yaml"; git -C "$Y2" add -f orca.yaml; yrun --check
check "roles-yaml --check: tracked orca.yaml with a chained launch.sh is silent" "$RC:$OUT" "0:"; git -C "$Y2" rm -q -f --cached orca.yaml
# --check outside a plain checkout (submodule, separate git dir) is silent and exits 0
SUBS="$TMP/ysubs"; mkdir -p "$SUBS/inner" "$SUBS/super"; git -C "$SUBS/inner" init -q; git -C "$SUBS/inner" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
git -C "$SUBS/super" init -q; git -C "$SUBS/super" -c protocol.file.allow=always submodule add -q "$SUBS/inner" s 2>/dev/null
git init -q --separate-git-dir "$SUBS/sep.git" "$SUBS/sep" 2>/dev/null
for d in "$SUBS/super/s" "$SUBS/sep"; do
  try env -u ORCA_CLI_COMMAND PATH="$FB:/usr/bin:/bin" FAKE_LOG="$YLOG" FAKE_PATH="$YP" bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" --check 2>&1' "$d" "$ROOT"
  check "roles-yaml --check: silent and rc 0 in $(basename "$d")" "$RC:$OUT" "0:"
done
yreset; hsjson shared-only "x" > "$YP"; printf 'x\n' > "$Y2/.worktreeinclude"; printf 'foo\n' > "$Y2/.git/info/exclude"; printf '%s' "$KIT_Y" > "$Y2/orca.yaml"
S3="$(git -C "$Y2" status --porcelain --ignored; shasum "$Y2/orca.yaml" "$Y2/.worktreeinclude" "$Y2/.git/info/exclude")"
yrun --check; check "roles-yaml --check never writes" "$(git -C "$Y2" status --porcelain --ignored; shasum "$Y2/orca.yaml" "$Y2/.worktreeinclude" "$Y2/.git/info/exclude")" "$S3"
yreset; hsjson local-only "npm i" > "$YP"; yrun --check; check "roles-yaml --check creates nothing" "$(LC_ALL=C ls -A "$Y2" | tr '\n' ' ')" ".git "
yreset; hsjson shared-only "npm i" > "$YP"; printf '%s' "$KIT_Y" > "$Y2/orca.yaml"; git -C "$Y2" add orca.yaml; git -C "$Y2" -c user.name=t -c user.email=t@t commit -q -m yaml
yrun --check; check "roles-yaml --check: shared-only, tracked orca.yaml with launch.sh is silent" "$RC:$OUT" "0:"
git -C "$Y2" rm -q -f orca.yaml; git -C "$Y2" -c user.name=t -c user.email=t@t commit -q -m rm-yaml
ychk MISSING "npm i"; check "roles-yaml --check: no source chosen with a local script is local-only and warns" "$RC:$OUT" "0:$W_LOCAL"
yreset; printf '{"ok":false,"error":{"code":"not_found"}}' > "$YP"; yrun --check; check "roles-yaml --check: project not registered is silent" "$RC:$OUT" "0:"
yreset; hsjson local-only "npm i" > "$YP"
check "roles-yaml --check: the warning goes to stderr, not stdout" "$(cd "$Y2" && env -u ORCA_CLI_COMMAND PATH="$FB:/usr/bin:/bin" FAKE_LOG="$YLOG" FAKE_PATH="$YP" FAKE_WT="$YW" FAKE_ID="$YI" "$ROOT/bin/orca-yaml.sh" --check 2>&1 >/dev/null):$(cd "$Y2" && env -u ORCA_CLI_COMMAND PATH="$FB:/usr/bin:/bin" FAKE_LOG="$YLOG" FAKE_PATH="$YP" FAKE_WT="$YW" FAKE_ID="$YI" "$ROOT/bin/orca-yaml.sh" --check 2>/dev/null | wc -c | tr -d ' ')" "$W_LOCAL:0"
try yaml "$TMP/ywt" --help; check "roles-yaml --help lists --check" "$RC:$(printf '%s\n' "$OUT" | grep -c -e '--check'):$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "0:1:6"
yreset; printf 'garbage' > "$YP"; yrun --check; check "roles-yaml --check: unexpected output is silent" "$RC:$OUT" "0:"
mkdir -p "$TMP/ynogit"; try env PATH="$FB:/usr/bin:/bin" bash -c 'cd "$0" && GIT_CEILING_DIRECTORIES="$0/.." "$1/bin/orca-yaml.sh" --check 2>&1' "$TMP/ynogit" "$ROOT"; check "roles-yaml --check: outside a git repo is silent" "$RC:$OUT" "0:"
}

sec_launch_overrides() {
# launch.sh exceptions (the project's setup script): --only, --enable, --disable, --set, saved per worktree
check "overrides: lists and typed --set" "$(overrides_from_args --only planner,dev --disable 'x, y' --set roles.dev.model=m1 --set=settings.jiraHandoff=false --set roles.t.params.n=5)" \
  '{"only":["planner","dev"],"enable":[],"disable":["x","y"],"set":[{"path":["roles","dev","model"],"value":"m1"},{"path":["settings","jiraHandoff"],"value":false},{"path":["roles","t","params","n"],"value":5}]}'
try overrides_from_args --nope 2>/dev/null; check "overrides: unknown option" "$RC" "1"
try overrides_from_args --set novalue 2>/dev/null; check "overrides: --set without =" "$RC" "1"
write_launch_config
overrides_from_args --only dev --enable tester --set roles.dev.model=m2 > "$TMP/ovr.json"
check "apply_overrides: --only keeps planner and dev, --enable adds tester" "$(apply_overrides "$KIT/config.json" "$TMP/ovr.json" > "$TMP/c.json"; enabled_roles "$TMP/c.json" | tr '\n' ' ')" "planner dev tester "
check "apply_overrides: --set" "$(jq -r '.roles.dev.model' "$TMP/c.json")" "m2"
overrides_from_args --disable planner,nobody > "$TMP/ovr.json"
check "check_overrides: unknown role" "$(check_overrides "$KIT/config.json" "$TMP/ovr.json" | grep -c '^ERROR: unknown roles: nobody\. Available: ')" "1"
check "check_overrides: the planner cannot be disabled" "$(check_overrides "$KIT/config.json" "$TMP/ovr.json" | grep -c '^ERROR: the planner cannot be disabled$')" "1"
}

sec_launch() {
write_launch_config
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
# launch.sh warns when new worktrees would not start the kit, and a failing check never changes its outcome
mkdir -p "$TMP/lbin2"; cat > "$TMP/lbin2/orca" <<'EOS'
#!/bin/sh
case "$1 $2" in
  "terminal create") while [ $# -gt 0 ]; do [ "$1" = --title ] && t="$2"; shift; done; echo "{\"handle\":\"h-$t\"}";;
  "terminal show") [ -n "$FAKE_SHOW" ] && echo "$FAKE_SHOW" && exit 0; exit 1;;
  "repo show") cat "$FAKE_REPO" 2>/dev/null;;
esac
exit 0
EOS
chmod +x "$TMP/lbin2/orca"
launch2() { (cd "$L" && HOME="$TMP/home" PATH="$TMP/lbin2:$PATH" FAKE_REPO="$TMP/l2.json" FAKE_SHOW="${FAKE_SHOW:-}" "$TMP/home/.orca-roles/bin/launch.sh" "$@" 2>&1); }
printf '%s' '{"ok":true,"result":{"repo":{"hookSettings":{"commandSourcePolicy":"local-only","scripts":{"setup":"npm i"}}}}}' > "$TMP/l2.json"
try launch2 --reset; check "launch: warns when new worktrees would not start the kit, exits 0, team saved" "$RC:$(printf '%s\n' "$OUT" | grep -c 'WARNING: new worktrees of this project will not start the kit: Orca.s setup source is local-only'):$(handles)" "0:1:PLANNER DEV DEPLOYER "
printf '%s' '{"ok":true,"result":{"repo":{"hookSettings":{"commandSourcePolicy":"local-only","scripts":{"setup":"$HOME/.orca-roles/bin/launch.sh"}}}}}' > "$TMP/l2.json"
try launch2 --reset; check "launch: no warning when the kit starts" "$RC:$(printf '%s\n' "$OUT" | grep -c 'WARNING')" "0:0"
printf 'garbage' > "$TMP/l2.json"
try launch2 --reset; check "launch: a failing check does not change the outcome" "$RC:$(printf '%s\n' "$OUT" | grep -c 'WARNING'):$(handles)" "0:0:PLANNER DEV DEPLOYER "
printf '%s' '{"ok":true,"result":{"repo":{"hookSettings":{"commandSourcePolicy":"local-only","scripts":{"setup":"npm i"}}}}}' > "$TMP/l2.json"
try launch2 --reset; check "launch: the warning comes after the team is saved and before it is printed" "$RC:$(printf '%s\n' "$OUT" | grep -n 'WARNING' | cut -d: -f1 | head -1):$(printf '%s\n' "$OUT" | grep -n '^PLANNER=' | cut -d: -f1 | head -1)" "0:$(printf '%s\n' "$OUT" | grep -n 'WARNING' | cut -d: -f1 | head -1):$(( $(printf '%s\n' "$OUT" | grep -n 'WARNING' | cut -d: -f1 | head -1) + 1 ))"
FAKE_SHOW='{"result":{"terminal":{"agentIdentity":"claude"}}}' try launch2; check "launch: the warning also shows when every role is already open" "$RC:$(printf '%s\n' "$OUT" | grep -c 'All roles are already open'):$(printf '%s\n' "$OUT" | grep -c 'WARNING: new worktrees of this project will not start the kit')" "0:1:1"
sleep 1   # lets the background kickoffs finish before the temporary directory is deleted
}

sec_status() {
# launch.sh --status: read-only report of the saved team
write_launch_config
S="$TMP/sproj"; mkdir -p "$S" "$TMP/sbin"; git -C "$S" init -q; G="$S/.git"
SLOG="$TMP/sorca.log"; : > "$SLOG"
cat > "$TMP/sbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$SLOG"
case "\$1 \$2" in
  "terminal show") case "\$4" in
    h-up) echo '{"result":{"terminal":{"agentIdentity":"claude"}}}';;
    h-gone) echo '{"result":{"terminal":{"title":"x"}}}';;
    *) exit 1;; esac;;
esac
exit 0
EOS
chmod +x "$TMP/sbin/orca"
status() { (cd "$S" && HOME="$TMP/home" PATH="$TMP/sbin:$PATH" ORCA_ROLES_AGENT_CHECKS=1 "$TMP/home/.orca-roles/bin/launch.sh" "$@" 2>&1); }
try status --status; check "status: no state" "$RC:$OUT" "0:No team launched in this worktree."
: > "$G/orca-roles.env"; try status --status; check "status: empty state" "$RC:$OUT" "0:No team launched in this worktree."
jq '.settings.mode = "programmer"' "$KIT/config.json" > "$G/orca-roles.config.json"
jq '.roles.dev.model = "m-dev"' "$G/orca-roles.config.json" > "$G/c.tmp" && mv "$G/c.tmp" "$G/orca-roles.config.json"
printf 'PLANNER=h-up\nDEV=h-none\nDEPLOYER=h-gone\n' > "$G/orca-roles.env"
printf 'XDEV=m-x\nPLANNER=m-ok\nDEPLOYER=FAILED:m-bad\n' > "$G/orca-roles.models"
printf 'PLANNER=pty-1\n' > "$G/orca-roles.pty"; printf '{"only":["dev"],"enable":[],"disable":[],"set":[]}' > "$G/orca-roles.overrides.json"
ssum() { cat "$G/orca-roles.config.json" "$G/orca-roles.overrides.json" "$G/orca-roles.env" "$G/orca-roles.pty" "$G/orca-roles.models" | cksum; ls "$G" | cksum; }
S0="$(ssum)"; : > "$SLOG"
try status --status
check "status: report" "$RC:$(printf '%s' "$OUT" | tr '\t\n' '|/')" "0:Mode: programmer/Planner|h-up|alive|-|m-ok/Dev|h-none|no tab|m-dev|-/Deployer|h-gone|agent gone|-|FAILED:m-bad"
check "status: writes nothing" "$([ "$(ssum)" = "$S0" ] && echo unchanged || echo CHANGED):$([ -e "$G/orca-roles-launch.log" ] && echo log)" "unchanged:"
check "status: only reads terminals" "$(grep -vc '^terminal show ' "$SLOG")" "0"
try status -h; case "$OUT" in *"--status "*"changes nothing"*) echo "ok   status: -h prints the --status line";; *) echo "FAIL status -h: $OUT"; FAIL=1;; esac
# orphaned tab, a custom agent (only its tab counts) and a saved state without a saved config (falls back to the merged config)
cat > "$TMP/sbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$SLOG"
case "\$1 \$2" in
  "terminal show") case "\$4" in
    h-orph) echo '{"result":{"terminal":{"orphaned":true,"agentIdentity":"claude"}}}';;
    h-cust) echo '{"result":{"terminal":{"title":"x"}}}';;
    *) exit 1;; esac;;
esac
exit 0
EOS
jq '.roles.dev.agent = "custom" | .roles.dev.command = "c" | .settings.mode = "programmer"' "$G/orca-roles.config.json" > "$G/c.tmp" && mv "$G/c.tmp" "$G/orca-roles.config.json"
printf 'PLANNER=h-orph\nDEV=h-cust\nGHOST=h-cust\n' > "$G/orca-roles.env"; rm -f "$G/orca-roles.models"; S0="$(ssum 2>/dev/null)"
try status --status
check "status: orphaned, custom agent alive, role missing from the config (checked like claude)" "$RC:$(printf '%s' "$OUT" | tr '\t\n' '|/')" "0:Mode: programmer/Planner|h-orph|orphaned|-|-/Dev|h-cust|alive|m-dev|-/ghost|h-cust|agent gone|-|-"
mv "$G/orca-roles.config.json" "$G/cfg.saved"
printf '{"roles":{"dev":{"title":"Developer","model":"m-proj"}},"settings":{"mode":"programmer"}}' > "$S/.orca-roles.json"
printf 'DEV=h-none\n' > "$G/orca-roles.env"
try status --status
check "status: without a saved config uses the merged one" "$RC:$(printf '%s' "$OUT" | tr '\t\n' '|/')" "0:Mode: programmer/Developer|h-none|no tab|m-proj|-"
check "status: no saved config is not created" "$([ -e "$G/orca-roles.config.json" ] && echo created || echo absent):$([ -e "$G/orca-roles-launch.log" ] && echo log || echo nolog)" "absent:nolog"
# no saved config: the project's mode, a saved --mode, no jq error with an answering tab, nothing written, temp file gone
mkdir -p "$TMP/stmp"; printf 'DEV=h-cust\n' > "$G/orca-roles.env"
printf '{"settings":{"mode":"pr-reviewer"}}' > "$S/.orca-roles.json"; S0="$(ssum 2>/dev/null)"
OUT="$(cd "$S" && HOME="$TMP/home" PATH="$TMP/sbin:$PATH" TMPDIR="$TMP/stmp" ORCA_ROLES_AGENT_CHECKS=1 "$TMP/home/.orca-roles/bin/launch.sh" --status 2>"$TMP/status.err")"
check "status: no saved config, the project's mode" "$(printf '%s' "$OUT" | head -1)" "Mode: pr-reviewer"
check "status: no saved config, an answering tab prints no jq error" "$(grep -c 'jq: error' "$TMP/status.err")" "0"
check "status: no saved config writes nothing and removes its temp file" "$([ "$(ssum 2>/dev/null)" = "$S0" ] && echo unchanged || echo CHANGED):$(ls "$TMP/stmp" | wc -l | tr -d ' ')" "unchanged:0"
rm -f "$S/.orca-roles.json"
printf '{"only":[],"enable":[],"disable":[],"set":[],"mode":"pr-reviewer"}' > "$G/orca-roles.overrides.json"
try status --status; check "status: no saved config, a saved --mode" "$RC:$(printf '%s' "$OUT" | head -1)" "0:Mode: pr-reviewer"
rm -f "$G/orca-roles.overrides.json"
rm -f "$S/.orca-roles.json"; mv "$G/cfg.saved" "$G/orca-roles.config.json"
jq '.settings.mode = "pr-reviewer"' "$G/orca-roles.config.json" > "$G/c.tmp" && mv "$G/c.tmp" "$G/orca-roles.config.json"
try status --status; check "status: shows the saved mode" "$RC:$(printf '%s' "$OUT" | head -1)" "0:Mode: pr-reviewer"
# a hyphenated role (E2E_TESTER) and the model inherited from defaults
jq '.roles["e2e-tester"] = {title: "E2E-Tester"} | .defaults.model = "m-def"' "$G/orca-roles.config.json" > "$G/c.tmp" && mv "$G/c.tmp" "$G/orca-roles.config.json"
printf 'E2E_TESTER=h-up\nPLANNER=h-up\n' > "$G/orca-roles.env"
printf '#!/bin/sh\necho '"'"'{"result":{"terminal":{"agentIdentity":"claude"}}}'"'"'\n' > "$TMP/sbin/orca"
try status --status; check "status: hyphenated role and defaults.model" "$RC:$(printf '%s' "$OUT" | tail -n +2 | tr '\t\n' '|/')" "0:E2E-Tester|h-up|alive|m-def|-/Planner|h-up|alive|m-def|-"
try status -h; check "status: -h prints the whole header, ending at the open-team rule" "$(printf '%s\n' "$OUT" | tail -1 | cut -c1-38)" "# The mode of a worktree cannot change"
}

sec_modes() {
# Modes: selection (config < .orca-roles.json < --mode), roles per mode, prompts per mode and the open-team rule.
# Own test kit (never the clone) with a fake second mode, pr-reviewer: planner + rv, and a role with "modes":"all" that has no prompt for it.
pk_setup
mkdir -p "$PK/prompts/pr-reviewer"; for f in planner common-workers rv; do echo "# $f" > "$PK/prompts/pr-reviewer/$f.md"; done
: > "$PK/prompts/programmer/allrole.md"
cat > "$PK/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner", "modes": "all" },
             "dev": { "title": "Dev", "modes": ["programmer"] },
             "allrole": { "title": "Allrole", "modes": "all" },
             "rv": { "title": "Rv", "modes": ["pr-reviewer"] } } }
J
M="$TMP/mproj"; mkdir -p "$M" "$TMP/mbin"; git -C "$M" init -q; MG="$M/.git"
MLOG="$TMP/morca.log"; : > "$MLOG"
cat > "$TMP/mbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$MLOG"
case "\$1 \$2" in
  "terminal create") while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; echo "{\"handle\":\"h-\$t\"}";;
  "terminal list") [ -f "$TMP/m-listfail" ] && exit 1; exit 0;;
  "terminal show") [ -f "$TMP/m-alive" ] && { echo '{"agentIdentity":"claude"}'; exit 0; }; exit 1;;
esac
exit 0
EOS
chmod +x "$TMP/mbin/orca"; printf '#!/bin/sh\nexit 0\n' > "$TMP/mbin/kickoff"; chmod +x "$TMP/mbin/kickoff"
ml() { (cd "$M" && HOME="$PH" PATH="$TMP/mbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/mbin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PKL/bin/launch.sh" "$@" 2>&1); }
mh() { cut -d= -f1 "$MG/orca-roles.env" | tr '\n' ' '; }
mmode() { jq -r '.settings.mode' "$MG/orca-roles.config.json"; }
mcreates() { grep -c '^terminal create' "$MLOG" || true; }
mstate() { echo "$(cat "$MG/orca-roles.config.json" "$MG/orca-roles.env" 2>/dev/null | cksum) $(cat "$MG/orca-roles.overrides.json" 2>/dev/null | cksum)"; }
MC="$PK/config.json"

# mode ids: exact match, availability
check "mode_error: known and available" "$(KIT="$PK" mode_error programmer)" ""
check "mode_error: pr-reviewer available with its planner prompt" "$(KIT="$PK" mode_error pr-reviewer)" ""
check "mode_error: known but not available" "$(KIT="$PK" mode_error academic-writer)" "mode 'academic-writer' is not available yet"
for bad in Programmer PROGRAMMER ../x programmer/ "a b" foo "" "programmer " "pr-reviewer/../programmer" program pr programmer2 pr-reviewer-x; do
  check "mode_error rejects '$bad'" "$(KIT="$PK" mode_error "$bad")" "unknown mode '$bad' (modes: programmer, pr-reviewer, academic-writer)"
done
check "mode_of: default is programmer" "$(KIT="$PK" mode_of "$PKC")" "programmer"
check "default config: settings.mode and the roles' modes" "$(jq -c '[.settings.mode, .roles.planner.modes, ([.roles | to_entries[] | select(.key != "planner") | .value.modes] | unique)]' "$PKC")" '["programmer","all",[["programmer"]]]'
check "enabled_roles: no mode = today's roles" "$(KIT="$PK" enabled_roles "$PKC" | tr '\n' ' ')" "planner researcher dev tester auditor e2e-tester deployer "

# roles and prompts per mode (library level)
mcfg() { jq -c "$1" "$MC" > "$TMP/m.json"; }
check "enabled_roles: programmer" "$(KIT="$PK" enabled_roles "$MC" | tr '\n' ' ')" "planner dev allrole "
jq '.settings.mode = "pr-reviewer"' "$MC" > "$TMP/m-pr.json"
check "enabled_roles: pr-reviewer = planner + its roles + 'all'" "$(KIT="$PK" enabled_roles "$TMP/m-pr.json" | tr '\n' ' ')" "planner allrole rv "
check "prompts_dir_of follows the mode" "$(KIT="$PK" prompts_dir_of "$TMP/m-pr.json")" "$PK/prompts/pr-reviewer"
check "prompt_of: default path in the mode's folder" "$(KIT="$PK" prompt_of "$TMP/m-pr.json" rv)" "$PK/prompts/pr-reviewer/rv.md"
jq '.roles.dev.prompt = "/p/dev.md" | .roles.rv.prompt = {"pr-reviewer": "~/x/rv.md"} | .roles.allrole.prompt = {"programmer": "/p/all.md"}' "$TMP/m-pr.json" > "$TMP/m-pp.json"
check "prompt_of: object entry for the mode (accepts ~)" "$(KIT="$PK" prompt_of "$TMP/m-pp.json" rv)" "$HOME/x/rv.md"
check "prompt_of: string prompt is programmer only" "$(KIT="$PK" prompt_of "$TMP/m-pp.json" dev)" "$PK/prompts/pr-reviewer/dev.md"
check "prompt_of: object without entry for the mode falls back to the default" "$(KIT="$PK" prompt_of "$TMP/m-pp.json" allrole)" "$PK/prompts/pr-reviewer/allrole.md"
jq '.settings.mode = "programmer"' "$TMP/m-pp.json" > "$TMP/m-pp2.json"
check "prompt_of: string prompt in programmer" "$(KIT="$PK" prompt_of "$TMP/m-pp2.json" dev)" "/p/dev.md"
check "prompt_of: object entry in programmer" "$(KIT="$PK" prompt_of "$TMP/m-pp2.json" allrole)" "/p/all.md"
check "worker_msg: common-workers.md from the mode's folder" "$(cd "$M" && KIT="$PK" worker_msg "$TMP/m-pr.json" rv | grep -o "Read [^ ]*common-workers.md and [^ ]*rv.md")" "Read $PK/prompts/pr-reviewer/common-workers.md and $PK/prompts/pr-reviewer/rv.md"
check "launchable_roles: a role in the mode without prompt is skipped, with a warning" "$(KIT="$PK" launchable_roles "$TMP/m-pr.json" 2>&1 | tr '\n' ' ')" "planner Warning: role allrole is skipped: it has no prompt for mode pr-reviewer (expected $PK/prompts/pr-reviewer/allrole.md). rv "
jq '.roles.planner.prompt = {"pr-reviewer": "/nonexistent/planner.md"}' "$TMP/m-pr.json" > "$TMP/m-pl.json"
check "launchable_roles: the planner is never skipped, even without its prompt file" "$(KIT="$PK" launchable_roles "$TMP/m-pl.json" 2>/dev/null | tr '\n' ' ')" "planner rv "
jq '.roles.planner.modes = ["pr-reviewer"] | .roles.planner.enabled = false' "$MC" > "$TMP/m-pm.json"
check "enabled_roles: the planner runs in every mode, whatever its modes and enabled say" "$(KIT="$PK" enabled_roles "$TMP/m-pm.json" | tr '\n' ' ')" "planner dev allrole "
# validation of modes and prompt
check "check_config: valid" "$(KIT="$PK" check_config "$MC")" ""
for v in '["foo"]' '5' '[]' '["programmer","Foo"]' '"programmer"' '[1]'; do
  jq --argjson v "$v" '.roles.dev.modes = $v' "$MC" > "$TMP/m-bad.json"
  check "check_config rejects modes $v" "$(KIT="$PK" check_config "$TMP/m-bad.json" | grep -c '^ERROR: role dev: modes')" "1"
done
for v in '{"foo": "x"}' '{"programmer": 1}' '5' '["x"]'; do
  jq --argjson v "$v" '.roles.dev.prompt = $v' "$MC" > "$TMP/m-bad.json"
  check "check_config rejects prompt $v" "$(KIT="$PK" check_config "$TMP/m-bad.json" | grep -c '^ERROR: role dev: prompt')" "1"
done
# upgrade of a config from before modes
printf '%s' '{"roles":{"planner":{"title":"Planner","prompt":"/old/planner.md"},"dev":{"title":"Dev","prompt":"/old/dev.md"}}}' > "$TMP/m-old.json"
UP="$(upgrade_config "$PKC" "$TMP/m-old.json")"; printf '%s\n' "$UP" > "$TMP/m-up.json"
check "upgrade_config: adds settings.mode and keeps a string prompt" "$(jq -c '[.settings.mode, .roles.dev.prompt]' "$TMP/m-up.json")" '["programmer","/old/dev.md"]'
printf '%s' '{"roles":{"planner":{"title":"Planner"},"dev":{"title":"Dev"}}}' > "$TMP/m-old2.json"
check "a config without modes works: missing modes = programmer" "$(KIT="$PK" enabled_roles "$TMP/m-old2.json" | tr '\n' ' ')|$(KIT="$PK" mode_of "$TMP/m-old2.json")" "planner dev |programmer"

# launch.sh
try ml; check "launch: no mode = programmer, today's team" "$RC:$(mh):$(mmode)" "0:PLANNER DEV ALLROLE :programmer"
case "$OUT" in *"Mode: programmer"*) echo "ok   launch: reports the mode";; *) echo "FAIL launch does not report the mode: $OUT"; FAIL=1;; esac
check "launch: planner message states the mode and reads the mode's prompt" "$(cd "$M" && KIT="$PK" planner_msg "$MG/orca-roles.config.json" "$(mh | tr 'A-Z' 'a-z')" "$MG/orca-roles.env" "" "" 0 | grep -o 'Read [^ ]*planner.md\|Mode: [a-z-]*\.')" "$(printf 'Read %s/prompts/programmer/planner.md\nMode: programmer.' "$PK")"
rm -f "$M/.git/orca-roles.env"   # the team is closed: no live tab
try ml --mode pr-reviewer; check "launch --mode pr-reviewer: planner + the mode's roles" "$RC:$(mh):$(mmode)" "0:PLANNER RV :pr-reviewer"
case "$OUT" in *"Warning: role allrole is skipped: it has no prompt for mode pr-reviewer (expected $PKL/prompts/pr-reviewer/allrole.md)"*) echo "ok   launch: warns about the skipped role";; *) echo "FAIL launch skip warning: $OUT"; FAIL=1;; esac
MSG="$(cd "$M" && KIT="$PK" planner_msg "$MG/orca-roles.config.json" "planner rv" "$MG/orca-roles.env" "" "" 0)"
check "launch pr-reviewer: planner prompt from its folder, only its handles" "$(printf '%s' "$MSG" | grep -o 'Read [^ ]*planner.md\|Mode: [a-z-]*\.\|Handles:.*Rv=h-Rv\.' | tr '\n' '|')" "Read $PK/prompts/pr-reviewer/planner.md|Mode: pr-reviewer.|Handles: Rv=h-Rv.|"
check "launch: --mode is saved in the exceptions" "$(jq -r .mode "$MG/orca-roles.overrides.json")" "pr-reviewer"
rm -f "$MG/orca-roles.env"
try ml; check "launch: 'roles' without options keeps the saved mode" "$RC:$(mh):$(mmode)" "0:PLANNER RV :pr-reviewer"
rm -f "$MG/orca-roles.env"
try ml --reset; check "launch: --reset forgets the mode" "$RC:$(mh):$(mmode)" "0:PLANNER DEV ALLROLE :programmer"
check "launch: --reset leaves no saved mode" "$(ls "$MG/orca-roles.overrides.json" 2>/dev/null | wc -l | tr -d ' ')" "0"

# selection: settings.mode < .orca-roles.json < --mode
rm -f "$MG/orca-roles.env"; jq '.settings.mode = "pr-reviewer"' "$MC" > "$TMP/m.json" && mv "$TMP/m.json" "$MC"
try ml --reset; check "selection: settings.mode in config.json" "$RC:$(mmode)" "0:pr-reviewer"
rm -f "$MG/orca-roles.env"; echo '{ "settings": { "mode": "programmer" } }' > "$M/.orca-roles.json"
try ml; check "selection: .orca-roles.json beats settings.mode" "$RC:$(mmode)" "0:programmer"
rm -f "$MG/orca-roles.env"
try ml --mode pr-reviewer; check "selection: --mode beats both" "$RC:$(mmode)" "0:pr-reviewer"
rm -f "$MG/orca-roles.env" "$M/.orca-roles.json"
try ml --reset --mode programmer; check "selection: --mode programmer over a pr-reviewer settings.mode" "$RC:$(mmode)" "0:programmer"
rm -f "$MG/orca-roles.env"; jq '.settings.mode = "programmer"' "$MC" > "$TMP/m.json" && mv "$TMP/m.json" "$MC"
try ml --reset; check "back to the default mode" "$RC:$(mmode)" "0:programmer"
rm -f "$MG/orca-roles.env"
try ml --set settings.mode=pr-reviewer; check "selection: --set settings.mode" "$RC:$(mmode)" "0:pr-reviewer"
rm -f "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"

# rejections: nothing opened, nothing saved
ml --reset >/dev/null; B="$(mstate)"; N="$(mcreates)"
for bad in Programmer ../x '' programmer/ "a b" foo academic-writer; do
  try ml --mode "$bad"
  check "launch --mode '$bad' fails before anything opens or is saved" "$RC:$(mcreates):$(mstate)" "1:$N:$B"
done
try ml --mode Programmer; case "$OUT" in *"unknown mode 'Programmer' (modes: programmer, pr-reviewer, academic-writer)"*) echo "ok   launch: unknown mode message";; *) echo "FAIL unknown mode message: $OUT"; FAIL=1;; esac
try ml --mode academic-writer; case "$OUT" in *"mode 'academic-writer' is not available yet"*) echo "ok   launch: unavailable mode message";; *) echo "FAIL unavailable message: $OUT"; FAIL=1;; esac
try ml --mode=Programmer; check "launch --mode=<x> form is validated too" "$RC:$(mstate)" "1:$B"
try ml --set settings.mode=Programmer; check "launch --set settings.mode goes through the same validation" "$RC:$(mcreates):$(mstate)" "1:$N:$B"
try ml --set settings.mode=../x; check "launch --set settings.mode=../x fails" "$RC:$(mstate)" "1:$B"
try ml --set 'settings.mode=["pr-reviewer"]'; check "launch --set settings.mode with a non-string fails" "$RC:$(mstate)" "1:$B"
try ml --set settings.mode; check "launch --set settings.mode (no =) is a path=value error, nothing saved" "$RC:$(mstate):$(printf '%s' "$OUT" | grep -c 'ERROR: --set expects path=value (e.g. roles.dev.model=claude-opus-5-5): settings.mode')" "1:$B:1"
try ml --set 'settings={"mode":"programmer"}'; check "launch --set settings={...} is refused, nothing saved" "$RC:$(mstate):$(printf '%s' "$OUT" | grep -c 'ERROR: --set replaces one value, not a whole object')" "1:$B:1"
try ml --set 'roles={}'; check "launch --set roles={} is refused, nothing saved" "$RC:$(mstate):$(printf '%s' "$OUT" | grep -c 'ERROR: --set replaces one value, not a whole object')" "1:$B:1"
# a role not in the mode
rm -f "$MG/orca-roles.env"; ml --reset --mode pr-reviewer >/dev/null; rm -f "$MG/orca-roles.env"; B="$(mstate)"
for o in --enable --disable --only; do
  try ml --mode pr-reviewer "$o" dev; check "launch --mode pr-reviewer $o dev fails" "$RC:$(mstate)" "1:$B"
  case "$OUT" in *"role dev is not part of mode pr-reviewer (its modes: programmer)"*) echo "ok   launch $o: error names the mode";; *) echo "FAIL $o message: $OUT"; FAIL=1;; esac
done
try ml --mode pr-reviewer --only rv; check "launch --only with a role of the mode works" "$RC:$(mh)" "0:PLANNER RV "
B="$(mstate)"; N="$(mcreates)"
for o in "--mode Foo" "--mode academic-writer" "--only dev,rv" "--enable dev"; do
  # shellcheck disable=SC2086
  try ml --mode pr-reviewer $o; check "launch $o with saved exceptions: rejected, saved config and exceptions unchanged" "$RC:$(mcreates):$(mstate)" "1:$N:$B"
done
# invalid modes in a config
rm -f "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"; B="$(mstate)"; N="$(mcreates)"
echo '{ "roles": { "dev": { "modes": ["foo"] } } }' > "$M/.orca-roles.json"
try ml; check "launch: modes [\"foo\"] fails, nothing opened or saved" "$RC:$(mcreates):$(mstate)" "1:$N:$B"
case "$OUT" in *"role dev: modes has unknown mode ids (foo)"*) echo "ok   launch: invalid modes message";; *) echo "FAIL modes message: $OUT"; FAIL=1;; esac
rm -f "$M/.orca-roles.json"

# the saved mode is kept when later options omit --mode
rm -f "$MG/orca-roles.env"; ml --reset --mode pr-reviewer >/dev/null; rm -f "$MG/orca-roles.env"
try ml --set settings.language=Spanish; check "saved mode: --set without --mode stays in pr-reviewer" "$RC:$(mmode):$(mh)" "0:pr-reviewer:PLANNER RV "
check "saved mode: kept in the overrides" "$(jq -r .mode "$MG/orca-roles.overrides.json")" "pr-reviewer"
rm -f "$MG/orca-roles.env"
try ml --enable rv; check "saved mode: --enable of a role of the mode stays in pr-reviewer" "$RC:$(mmode):$(mh)" "0:pr-reviewer:PLANNER RV "
rm -f "$MG/orca-roles.env"
try ml --mode pr-reviewer --set settings.mode=programmer; check "--mode beats --set settings.mode" "$RC:$(mmode)" "0:pr-reviewer"
rm -f "$MG/orca-roles.env"
try ml --mode programmer; check "saved mode: another --mode changes it" "$RC:$(mmode)" "0:programmer"
rm -f "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"
# --set settings.mode is the same request as --mode: saved the same way
rm -f "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"
try ml --set settings.mode=pr-reviewer; check "--set settings.mode=pr-reviewer picks the mode" "$RC:$(mmode)" "0:pr-reviewer"
check "--set settings.mode is saved as the mode, not as a set entry" "$(jq -c '[.mode, ([.set[].path | join(".")] | index("settings.mode"))]' "$MG/orca-roles.overrides.json")" '["pr-reviewer",null]'
rm -f "$MG/orca-roles.env"
try ml --set settings.language=Spanish; check "--set settings.mode is kept by later options" "$RC:$(mmode)" "0:pr-reviewer"
rm -f "$MG/orca-roles.env"
try ml --reset --set settings.language=Spanish; check "--reset with other options drops the saved mode" "$RC:$(mmode):$(jq -r '.mode // "none"' "$MG/orca-roles.overrides.json")" "0:programmer:none"
rm -f "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"
# a settings that is not an object is an error, a missing one is programmer
for v in '"x"' null '[]' 5; do
  jq --argjson v "$v" '.settings = $v' "$MC" > "$TMP/m-bad.json"
  try env KIT="$PK" bash -c '. "$KIT/bin/lib.sh"; mode_of "$1" 2>/dev/null' _ "$TMP/m-bad.json"; check "mode_of rejects settings $v" "$RC" "1"
  check "check_config reports settings $v" "$(KIT="$PK" check_config "$TMP/m-bad.json" 2>/dev/null | grep -c '^ERROR')" "1"
done
jq 'del(.settings)' "$MC" > "$TMP/m-nosettings.json"; check "mode_of: no settings at all = programmer" "$(KIT="$PK" mode_of "$TMP/m-nosettings.json")" "programmer"
# a role without modes belongs to programmer even if the mode's folder has a prompt for it
: > "$PK/prompts/pr-reviewer/nomodes.md"
jq '.roles.nomodes = {"title": "Nomodes"}' "$MC" > "$TMP/m.json" && mv "$TMP/m.json" "$MC"
try ml --mode pr-reviewer; check "role without modes and with a prompt in the mode: not launched" "$RC:$(mh)" "0:PLANNER RV "
rm -f "$MG/orca-roles.env"; B="$(mstate)"
try ml --mode pr-reviewer --enable nomodes; check "role without modes: --enable in pr-reviewer is rejected" "$RC:$(mstate)" "1:$B"
rm -f "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"
# a config the checks cannot read fails closed
B="$(mstate)"; N="$(mcreates)"; echo '{ "roles": { "dev": "x" } }' > "$M/.orca-roles.json"
try ml; check "launch: a role that is not an object fails closed, nothing opened or saved" "$RC:$(mcreates):$(mstate)" "1:$N:$B"
case "$OUT" in *"ERROR: invalid configuration"*) echo "ok   launch: fails closed with an error";; *) echo "FAIL fail closed: $OUT"; FAIL=1;; esac
rm -f "$M/.orca-roles.json"
check "check_config: non-object role gives an error and not silence" "$(printf '%s' '{"roles":{"dev":"x"}}' > "$TMP/m-x.json"; KIT="$PK" check_config "$TMP/m-x.json" 2>/dev/null | grep -c '^ERROR')" "1"
# exact ids, and a settings.mode that is not a string is an error (a missing key is programmer)
check "mode_error: trailing newline" "$(KIT="$PK" mode_error $'programmer\n' | head -1 | cut -c1-12)" "unknown mode"
for v in false null 5 '["programmer"]' '"programmer\n"' '""'; do
  jq --argjson v "$v" '.settings.mode = $v' "$MC" > "$TMP/m-bad.json"
  try env KIT="$PK" bash -c '. "$KIT/bin/lib.sh"; mode_of "$1" 2>/dev/null' _ "$TMP/m-bad.json"; check "mode_of rejects settings.mode $v" "$RC" "1"
done
jq 'del(.settings.mode)' "$MC" > "$TMP/m-nokey.json"; check "mode_of: missing settings.mode = programmer" "$(KIT="$PK" mode_of "$TMP/m-nokey.json")" "programmer"
# an open team blocks a mode change
ml --reset >/dev/null; : > "$TMP/m-alive"; B="$(mstate)"; N="$(mcreates)"
try ml --mode pr-reviewer; check "open team: a mode change is rejected, nothing changes" "$RC:$(mcreates):$(mstate):$(mmode)" "1:$N:$B:programmer"
case "$OUT" in *"Close the team first"*"mode 'programmer'"*"'pr-reviewer'"*|*"mode 'programmer'"*"'pr-reviewer'"*"Close the team first"*) echo "ok   open team: the error explains it";; *) echo "FAIL open team message: $OUT"; FAIL=1;; esac
check "open team: the overrides were not saved" "$(ls "$MG/orca-roles.overrides.json" 2>/dev/null | wc -l | tr -d ' ')" "0"
try ml --mode programmer; check "open team: the same mode proceeds" "$RC:$(mmode)" "0:programmer"
check "open team: the same mode is saved" "$(jq -r .mode "$MG/orca-roles.overrides.json")" "programmer"
# a saved configuration from before modes (no settings.mode) counts as programmer
jq 'del(.settings.mode)' "$MG/orca-roles.config.json" > "$TMP/m.json" && mv "$TMP/m.json" "$MG/orca-roles.config.json"; B="$(mstate)"
try ml --mode pr-reviewer; check "open team: a saved config without settings.mode blocks the change" "$RC:$(mstate)" "1:$B"
# 'orca terminal list' failing for the whole wait: the open-team check cannot tell, so a mode change is refused
: > "$TMP/m-listfail"; B="$(mstate)"; N="$(mcreates)"
try ml --mode pr-reviewer; check "terminal list fails: a mode change with a saved team is refused, nothing changes" "$RC:$(mcreates):$(mstate)" "1:$N:$B"
case "$OUT" in *"cannot tell whether this worktree's team"*) echo "ok   terminal list fails: the error explains it";; *) echo "FAIL list failure message: $OUT"; FAIL=1;; esac
rm -f "$TMP/m-listfail"
rm -f "$TMP/m-alive"
try ml --mode pr-reviewer; check "closed team: the mode change proceeds" "$RC:$(mmode):$(mh)" "0:pr-reviewer:PLANNER RV "
# the team is open in pr-reviewer: every way back to another mode is rejected
: > "$TMP/m-alive"; B="$(mstate)"; N="$(mcreates)"
for o in --reset "--mode programmer" "--set settings.mode=programmer"; do
  # shellcheck disable=SC2086
  try ml $o; check "open team in pr-reviewer: $o is rejected, nothing changes" "$RC:$(mcreates):$(mstate)" "1:$N:$B"
done
rm -f "$TMP/m-alive"
# a user config.json from before modes (no settings.mode, no modes) launches the same programmer team as before
SAME="PLANNER RESEARCHER DEV TESTER AUDITOR E2E_TESTER DEPLOYER "
jq 'del(.settings.mode) | del(.roles[].modes) | .settings += {kickoffTimeoutSeconds: 1, launchWaitSeconds: 1, closeComposerAgent: false, jiraHandoff: false}' "$PKC" > "$TMP/m-legacy.json"
check "legacy config: has neither settings.mode nor modes" "$(jq -c '[.settings.mode, ([.roles[].modes] | map(select(. != null)) | length)]' "$TMP/m-legacy.json")" "[null,0]"
rm -f "$MG/orca-roles.env"; cp "$TMP/m-legacy.json" "$MC"
try ml --reset; check "legacy config: the same programmer team as before" "$RC:$(mh):$(mmode)" "0:$SAME:programmer"
rm -f "$MG/orca-roles.env"; upgrade_config "$PKC" "$TMP/m-legacy.json" > "$MC"
try ml --reset; check "legacy config after upgrade_config: the same programmer team" "$RC:$(mh):$(mmode)" "0:$SAME:programmer"
sleep 1
rm -rf "$PK/prompts/pr-reviewer" "$PK/prompts/programmer/allrole.md" "$PK/config.json"   # the kit copy is shared with other sections
}

sec_new_role_modes() {
# new-role.sh with modes: one prompt per mode (wizard and --from-json), --repo layout, --remove, overwrite and launching.
# Own test kit (never the clone) with a fake second mode, pr-reviewer.
pk_setup
mkdir -p "$PK/prompts/pr-reviewer"; for f in planner common-workers; do echo "# $f" > "$PK/prompts/pr-reviewer/$f.md"; done
cat > "$PK/config.json" <<'J'
{ "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner", "modes": "all" }, "dev": { "title": "Dev" } } }
J
rm -rf "$PK/roles"
NRC="$PK/config.json"
nrj() { (cd "$TMP" && HOME="$PH" "$PKL/bin/new-role.sh" --from-json "$1" 2>&1); }
nrm() { (cd "$TMP" && HOME="$PH" "$PKL/bin/new-role.sh" --remove "$1" 2>&1); }
snap() { { cat "$NRC"; find "$PK/roles" -type f 2>/dev/null | sort; ls "$PK"; } | cksum; }
RP='# x\n## Report\n'
nr_mode_cfg() { jq --arg m "$1" '.settings.mode = $m' "$NRC" > "$TMP/nrm-$1.json"; echo "$TMP/nrm-$1.json"; }

# --from-json: pass
printf '%s' '{"id":"rv","description":"d","modes":"pr-reviewer","prompt":"'"$RP"'"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "modes from-json: one mode (string)" "$RC:$(jq -c '.roles.rv | [.modes, .prompt]' "$NRC")" "0:[[\"pr-reviewer\"],{\"pr-reviewer\":\"$PH/.orca-roles/roles/pr-reviewer/rv.md\"}]"
check "modes from-json: file in roles/<mode>/, none for programmer" "$(head -1 "$PK/roles/pr-reviewer/rv.md"):$([ -e "$PK/roles/programmer/rv.md" ] && echo left):$([ -e "$PK/roles/rv.md" ] && echo flat)" "# x::"
check "modes from-json: launched in pr-reviewer, not in programmer" "$(KIT="$PK" launchable_roles "$(nr_mode_cfg pr-reviewer)" 2>&1 | tr '\n' ' ')|$(KIT="$PK" launchable_roles "$(nr_mode_cfg programmer)" 2>&1 | tr '\n' ' ')" "planner rv |planner dev "
printf '%s' '{"id":"rv-list","description":"d","modes":["pr-reviewer"],"prompt":"'"$RP"'"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "modes from-json: one-element list" "$RC:$(jq -c '.roles["rv-list"].modes' "$NRC")" '0:["pr-reviewer"]'
printf '%s' '{"id":"al","description":"d","modes":"all","prompt":{"programmer":"# p\n## Report\n","pr-reviewer":"# r\n## Report\n","academic-writer":"# a\n## Report\n"}}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "modes from-json: all with an object" "$RC:$(jq -c '.roles.al | [.modes, (.prompt | keys)]' "$NRC")" '0:["all",["academic-writer","pr-reviewer","programmer"]]'
check "modes from-json: all writes three files" "$(for m in programmer pr-reviewer academic-writer; do head -n1 "$PK/roles/$m/al.md"; done | tr '\n' ' ')" "# p # r # a "
case "$OUT" in *"mode 'academic-writer' is not available yet"*) echo "ok   modes from-json: notes the unavailable mode";; *) echo "FAIL unavailable note: $OUT"; FAIL=1;; esac
printf '%s' '{"id":"legacy","description":"d","prompt":"# p\n## Report\n"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "modes from-json: no modes + string prompt = programmer" "$RC:$(jq -c '.roles.legacy.modes' "$NRC"):$([ -f "$PK/roles/programmer/legacy.md" ] && echo y)" '0:["programmer"]:y'
printf '%s' '{"id":"nowarn","description":"d","prompt":"# no report"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; case "$OUT" in *"prompt for mode programmer has no '## Report'"*) echo "ok   modes from-json: Report warning per file";; *) echo "FAIL Report warning: $OUT"; FAIL=1;; esac

# --from-json: fail, nothing written
S0="$(snap)"
nr_fail() {  # <name> <json>
  printf '%s' "$2" > "$TMP/nj.json"; try nrj "$TMP/nj.json"
  check "modes from-json rejects $1" "$RC:$([ "$(snap)" = "$S0" ] && echo unchanged || echo CHANGED)" "1:unchanged"
}
nr_fail "all with a string prompt" '{"id":"f1","description":"d","modes":"all","prompt":"# x\n## Report\n"}'
nr_fail "an object missing a mode" '{"id":"f2","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r"}}'
nr_fail "an object with an extra mode" '{"id":"f3","description":"d","modes":"pr-reviewer","prompt":{"pr-reviewer":"# r","programmer":"# p"}}'
nr_fail "an object for one mode with another key" '{"id":"f3b","description":"d","modes":"pr-reviewer","prompt":{"programmer":"# p"}}'
nr_fail "modes ../x" '{"id":"f4","description":"d","modes":"../x","prompt":"# x"}'
nr_fail "modes Programmer" '{"id":"f5","description":"d","modes":"Programmer","prompt":"# x"}'
nr_fail "two modes in a list" '{"id":"f6","description":"d","modes":["programmer","pr-reviewer"],"prompt":{"programmer":"# p","pr-reviewer":"# r"}}'
nr_fail "a prompt value that is not a string" '{"id":"f7","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":5,"academic-writer":"# a"}}'
nr_fail "a mode with a trailing newline" '{"id":"f8","description":"d","modes":"programmer\n","prompt":"# x"}'
nr_fail "an empty modes list" '{"id":"f9","description":"d","modes":[],"prompt":"# x"}'
nr_fail "modes null" '{"id":"f10","description":"d","modes":null,"prompt":"# x"}'
nr_fail "a path as a prompt key" '{"id":"f11","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-writer":"# a","../x":"# b"}}'
nr_fail "an array prompt" '{"id":"f12","description":"d","prompt":["# x"]}'
nr_fail "a two-mode list with a string prompt" '{"id":"f13","description":"d","modes":["programmer","pr-reviewer"],"prompt":"# x\n## Report\n"}'
nr_fail "a blank prompt" '{"id":"f14","description":"d","prompt":"   "}'
nr_fail "the id common-workers (local)" '{"id":"common-workers","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-writer":"# a"}}'
nr_fail "the id planner" '{"id":"planner","description":"d","prompt":"# x"}'
nr_fail "a path as id" '{"id":"../x","description":"d","prompt":"# x"}'

printf '%s' '{"id":"aw","description":"d","modes":"academic-writer","prompt":"# a\n## Report\n"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "modes from-json: a single not-available mode is accepted with the note" "$RC:$(jq -c '.roles.aw.modes' "$NRC"):$([ -f "$PK/roles/academic-writer/aw.md" ] && echo y)" '0:["academic-writer"]:y'
case "$OUT" in *"Note: mode 'academic-writer' is not available yet"*) echo "ok   modes from-json: the note for a single unavailable mode";; *) echo "FAIL single unavailable note: $OUT"; FAIL=1;; esac

# overwrite shrinks the modes: no orphans
touch "$PK/roles/al.md"
printf '%s' '{"id":"al","description":"d","modes":"programmer","overwrite":true,"prompt":"# p2\n## Report\n"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "modes overwrite: the modes it no longer has lose their prompts" "$RC:$([ -e "$PK/roles/pr-reviewer/al.md" ] && echo left):$([ -e "$PK/roles/academic-writer/al.md" ] && echo left):$([ -e "$PK/roles/al.md" ] && echo legacy):$(head -1 "$PK/roles/programmer/al.md"):$(jq -c '.roles.al.modes' "$NRC")" '0::::# p2:["programmer"]'
printf '%s' '{"id":"fresh","description":"d","modes":"pr-reviewer","prompt":"# f\n## Report\n"}' > "$TMP/nj.json"; mkdir -p "$PK/roles/programmer"; echo keep > "$PK/roles/programmer/fresh.md"
try nrj "$TMP/nj.json"; check "modes: a new role does not delete a stray file of another mode" "$RC:$(cat "$PK/roles/programmer/fresh.md")" "0:keep"
rm -f "$PK/roles/programmer/fresh.md"

# --remove
printf '%s' '{"id":"rm-a","description":"d","modes":"all","prompt":{"programmer":"# p\n## Report\n","pr-reviewer":"# r\n## Report\n","academic-writer":"# a\n## Report\n"}}' > "$TMP/nj.json"; nrj "$TMP/nj.json" >/dev/null
touch "$PK/roles/rm-a.md" "$PK/roles/programmer/rm-b.md" "$TMP/outside.md"
jq --arg o "$TMP/outside.md" '.roles["rm-a"].prompt["academic-writer"] = $o' "$NRC" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$NRC"
try nrm rm-a; check "modes remove: per-mode and legacy prompts are deleted" "$RC:$(ls "$PK/roles/programmer/rm-a.md" "$PK/roles/pr-reviewer/rm-a.md" "$PK/roles/academic-writer/rm-a.md" "$PK/roles/rm-a.md" 2>/dev/null | wc -l | tr -d ' '):$(jq -r '.roles | has("rm-a")' "$NRC")" "0:0:false"
check "modes remove: a prompt outside the kit and other roles' files stay" "$([ -f "$TMP/outside.md" ] && echo y)$([ -f "$PK/roles/programmer/rm-b.md" ] && echo y)" "yy"
case "$OUT" in *"outside the kit and was left alone: $TMP/outside.md"*) echo "ok   modes remove: says the outside prompt was left alone";; *) echo "FAIL remove outside: $OUT"; FAIL=1;; esac
try nrm ../x; check "modes remove: an id with a path is refused" "$RC" "1"
jq '.roles["../x"] = {"title": "X"}' "$NRC" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$NRC"; S2="$(snap)"
try nrm ../x; check "modes remove: a '../x' role in the config reaches the id check, nothing changes" "$RC:$([ "$(snap)" = "$S2" ] && echo unchanged)" "1:unchanged"; case "$OUT" in *"Invalid id"*) echo "ok   modes remove: invalid id message";; *) echo "FAIL remove invalid id: $OUT"; FAIL=1;; esac
jq 'del(.roles["../x"])' "$NRC" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$NRC"
try nrm common-workers; check "modes remove: common-workers is refused" "$RC" "1"

# wizard (answers: id, title, description, modes, then the claude defaults up to the prompts)
SRC="$TMP/nw-src.md"; printf '# Role: W\n\n## Report\nx\n' > "$SRC"
nrw() {  # nrw <answers file>
  (cd "$TMP" && HOME="$PH" NEW_ROLE_TTY="$1" "$PKL/bin/new-role.sh" < /dev/null 2>&1)
}
printf '%s\n' wz-one "" "wizard one" 2 2 "" "" "" n "" "" "" "" "" "" "" "" 2 "$SRC" y > "$TMP/nw1.in"
try nrw "$TMP/nw1.in"; check "modes wizard: one mode" "$RC:$(jq -c '.roles["wz-one"] | [.modes, .prompt]' "$NRC"):$(cmp -s "$SRC" "$PK/roles/pr-reviewer/wz-one.md" && echo same)" "0:[[\"pr-reviewer\"],{\"pr-reviewer\":\"$PH/.orca-roles/roles/pr-reviewer/wz-one.md\"}]:same"
check "modes wizard: launched in its mode" "$(KIT="$PK" launchable_roles "$(nr_mode_cfg pr-reviewer)" 2>&1 | tr '\n' ' ')" "planner rv rv-list fresh wz-one "
printf '%s\n' wz-all "" "wizard all" 1 "" "" "" n "" "" "" "" "" "" "" "" 2 "$SRC" 4 4 y > "$TMP/nw2.in"
try nrw "$TMP/nw2.in"; check "modes wizard: all, the copy option for the 2nd and 3rd" "$RC:$(jq -c '.roles["wz-all"] | [.modes, (.prompt | keys)]' "$NRC"):$(cmp -s "$SRC" "$PK/roles/programmer/wz-all.md" && cmp -s "$SRC" "$PK/roles/pr-reviewer/wz-all.md" && cmp -s "$SRC" "$PK/roles/academic-writer/wz-all.md" && echo same)" '0:["all",["academic-writer","pr-reviewer","programmer"]]:same'
case "$OUT" in *"4) Copy the prompt of pr-reviewer"*) echo "ok   modes wizard: offers the copy option";; *) echo "FAIL wizard options: $OUT"; FAIL=1;; esac
case "$OUT" in *"Note: mode 'academic-writer' is not available yet"*) echo "ok   modes wizard: notes the unavailable mode";; *) echo "FAIL wizard note: $OUT"; FAIL=1;; esac
case "$OUT" in *"programmer: $PH/.orca-roles/roles/programmer/wz-all.md"*"academic-writer: $PH/.orca-roles/roles/academic-writer/wz-all.md"*) echo "ok   modes wizard: the summary lists each mode's file";; *) echo "FAIL wizard summary: $OUT"; FAIL=1;; esac
SRC2="$TMP/nw-src2.md"; printf '# Role: W2\n\n## Report\ny\n' > "$SRC2"
printf '%s\n' wz-chain "" "wizard chain" 1 "" "" "" n "" "" "" "" "" "" "" "" 2 "$SRC" 2 "$SRC2" 4 y > "$TMP/nw4.in"
try nrw "$TMP/nw4.in"; check "modes wizard: the copy option copies the previous mode's prompt, not the first" "$RC:$(cmp -s "$SRC" "$PK/roles/programmer/wz-chain.md" && echo p):$(cmp -s "$SRC2" "$PK/roles/pr-reviewer/wz-chain.md" && echo r):$(cmp -s "$SRC2" "$PK/roles/academic-writer/wz-chain.md" && echo a)" "0:p:r:a"
printf '%s\n' wz-bad "" "x" 2 9 > "$TMP/nw3.in"; S1="$(snap)"
try nrw "$TMP/nw3.in"; check "modes wizard: an invalid mode is refused, nothing written" "$RC:$([ "$(snap)" = "$S1" ] && echo unchanged)" "1:unchanged"

# --repo layout
NR="$TMP/nrm-repo"; mkdir -p "$NR"; cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$NR/"
nrr() { (cd "$TMP" && HOME="$PH" "$PKL/bin/new-role.sh" "$@" 2>&1); }
nrr_w() { (cd "$TMP" && HOME="$PH" NEW_ROLE_TTY="$1" "$PKL/bin/new-role.sh" --repo "$NR" < /dev/null 2>&1); }
printf '%s' '{"id":"rp","description":"d","modes":"pr-reviewer","prompt":"# r\n## Report\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: prompts/<mode>/<id>.md (folder created), no prompt field" "$RC:$([ -f "$NR/prompts/pr-reviewer/rp.md" ] && echo y):$(jq -c '.roles.rp | [.modes, .prompt]' "$NR/config.default.json")" '0:y:[["pr-reviewer"],null]'
check "modes --repo: nothing in the installation" "$([ -e "$PK/roles/pr-reviewer/rp.md" ] && echo local)" ""
printf '%s' '{"id":"rp-all","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-writer":"# a"}}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: all writes three files" "$RC:$(ls "$NR/prompts/programmer/rp-all.md" "$NR/prompts/pr-reviewer/rp-all.md" "$NR/prompts/academic-writer/rp-all.md" | wc -l | tr -d ' ')" "0:3"
# the installed kit's own files are left alone by --repo overwrite/remove (T3), and the clone's availability decides the note (D4)
mkdir -p "$PK/roles"; echo inst > "$PK/roles/rp-all.md"
printf '%s' '{"id":"rp-all","description":"d","modes":"programmer","overwrite":true,"prompt":"# p2\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"
check "modes --repo overwrite: lost modes are listed, not deleted; the installed legacy file stays" "$RC:$(ls "$NR/prompts/pr-reviewer/rp-all.md" "$NR/prompts/academic-writer/rp-all.md" | wc -l | tr -d ' '):$(cat "$PK/roles/rp-all.md")" "0:2:inst"
case "$OUT" in *"prompts/pr-reviewer/rp-all.md is no longer used by 'rp-all'; remove it with: git -C $NR rm prompts/pr-reviewer/rp-all.md"*"prompts/academic-writer/rp-all.md is no longer used"*) echo "ok   modes --repo overwrite: tells how to remove them with git";; *) echo "FAIL repo overwrite listing: $OUT"; FAIL=1;; esac
printf '%s' '{"id":"rp-pr","description":"d","modes":"pr-reviewer","prompt":"# r\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; case "$OUT" in *"Note: mode 'pr-reviewer' is not available yet"*) echo "ok   modes --repo: availability is checked in the clone, not the installation";; *) echo "FAIL repo availability note: $OUT"; FAIL=1;; esac
try nrr --remove rp-pr --repo "$NR"
# D1: kit files cannot be taken over
echo kit > "$NR/prompts/programmer/common-workers.md"; echo kit > "$NR/prompts/pr-reviewer/common-workers.md"; echo kit > "$NR/prompts/programmer/lone.md"
R0="$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)"
printf '%s' '{"id":"common-workers","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-writer":"# a"}}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: common-workers is refused, nothing written" "$RC:$([ "$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)" = "$R0" ] && echo unchanged)" "1:unchanged"
printf '%s' '{"id":"lone","description":"d","prompt":"# l\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: an existing prompts file blocks a new role, nothing written" "$RC:$([ "$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)" = "$R0" ] && echo unchanged)" "1:unchanged"
try nrr --remove common-workers --repo "$NR"; check "modes --repo: --remove never deletes common-workers" "$RC:$(cat "$NR/prompts/programmer/common-workers.md")" "1:kit"
rm -f "$NR/prompts/programmer/lone.md"
# the wizard in the repo: no prompt field, collision and reserved ids
printf '%s\n' wz-repo "" "wizard repo" 2 1 "" "" "" n "" "" "" "" "" "" "" "" 2 "$SRC" y n > "$TMP/nw4.in"
try nrr_w "$TMP/nw4.in"; check "modes wizard --repo: modes, no prompt field, file in prompts/<mode>/" "$RC:$(jq -c '.roles["wz-repo"] | [.modes, .prompt]' "$NR/config.default.json"):$([ -f "$NR/prompts/programmer/wz-repo.md" ] && echo y)" '0:[["programmer"],null]:y'
printf '%s\n' common-workers wz-x "x" 2 1 > "$TMP/nw5.in"; R1="$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)"
try nrr_w "$TMP/nw5.in"; case "$OUT" in *"'common-workers' is reserved"*) echo "ok   modes wizard: common-workers is reserved";; *) echo "FAIL wizard reserved: $OUT"; FAIL=1;; esac
printf '%s\n' lone "" "x" 2 1 > "$TMP/nw6.in"; echo kit > "$NR/prompts/programmer/lone.md"; R1="$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)"
try nrr_w "$TMP/nw6.in"; check "modes wizard --repo: an existing prompts file blocks a new role" "$RC:$(printf '%s' "$OUT" | grep -q "prompts/programmer/lone.md already exists" && echo msg):$([ "$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)" = "$R1" ] && echo unchanged)" "1:msg:unchanged"
echo kit > "$NR/prompts/academic-writer/lone2.md"; R1="$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)"
printf '%s' '{"id":"lone2","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-writer":"# a"}}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: a file in a later mode blocks a new role, nothing written" "$RC:$(printf '%s' "$OUT" | grep -q "prompts/academic-writer/lone2.md already exists" && echo msg):$([ "$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)" = "$R1" ] && echo unchanged)" "1:msg:unchanged"
rm -f "$NR/prompts/academic-writer/lone2.md"
rm -f "$NR/prompts/programmer/lone.md"; try nrr --remove wz-repo --repo "$NR"
try nrr --remove rp --repo "$NR"; try nrr --remove rp-all --repo "$NR"
check "modes --repo: --remove deletes every mode's prompt" "$(ls "$NR"/prompts/*/rp.md "$NR"/prompts/*/rp-all.md 2>/dev/null | wc -l | tr -d ' '):$(find "$NR/prompts/programmer" -name '*.md' | wc -l | tr -d ' ')" "0:8"
check "modes --repo: --remove --repo leaves the installed legacy file" "$(cat "$PK/roles/rp-all.md" 2>/dev/null)" "inst"
printf '%s' '{"id":"dev","description":"d","modes":"pr-reviewer","overwrite":true,"prompt":"# r\n## Report\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: overwriting a default role with fewer modes keeps the lost mode's prompt and lists it" "$RC:$([ -e "$NR/prompts/programmer/dev.md" ] && echo left):$([ -f "$NR/prompts/pr-reviewer/dev.md" ] && echo y):$(jq -c '.roles.dev.modes' "$NR/config.default.json"):$(printf '%s' "$OUT" | grep -c "prompts/programmer/dev.md is no longer used by 'dev'; remove it with: git -C $NR rm prompts/programmer/dev.md")" '0:left:y:["pr-reviewer"]:1'
# the git hint quotes a clone path with a space
NS="$TMP/my clone"; mkdir -p "$NS"; cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$NS/"
git -C "$NS" init -q && git -C "$NS" add -A && git -C "$NS" -c user.name=t -c user.email=t@t commit -q -m init
printf '%s' '{"id":"rp-sp","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-writer":"# a"}}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NS"; git -C "$NS" add -A && git -C "$NS" -c user.name=t -c user.email=t@t commit -q -m rp-sp
printf '%s' '{"id":"rp-sp","description":"d","modes":"programmer","overwrite":true,"prompt":"# p2\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NS"
HINT="$(printf '%s\n' "$OUT" | grep '^prompts/pr-reviewer/rp-sp.md' | sed 's/.*remove it with: //')"
case "$HINT" in "git -C "*my*clone*rm*prompts/pr-reviewer/rp-sp.md) (eval "$HINT" >/dev/null 2>&1) || true; check "modes --repo overwrite: the printed git command for a path with a space runs" "$([ -e "$NS/prompts/pr-reviewer/rp-sp.md" ] && echo left)" "";; *) echo "FAIL quoted git hint: $HINT"; FAIL=1;; esac
# a local role created before the id was reserved can be removed; the kit's prompts and --repo stay protected
mkdir -p "$PK/roles/programmer" "$PK/prompts/programmer"; echo kit > "$PK/prompts/programmer/common-workers.md"; echo loc > "$PK/roles/programmer/common-workers.md"
jq '.roles["common-workers"] = {title: "CW"}' "$NRC" > "$TMP/cw.json" && mv "$TMP/cw.json" "$NRC"
try nrr --remove common-workers --repo "$NR"; check "modes: --remove common-workers --repo is refused" "$RC:$(printf '%s' "$OUT" | grep -c "'common-workers' is a kit file, not a role"):$([ -f "$PK/roles/programmer/common-workers.md" ] && echo kept)" "1:1:kept"
cp "$NR/config.default.json" "$TMP/nrcd.bak"; jq '.roles["common-workers"] = {title: "CW"}' "$TMP/nrcd.bak" > "$NR/config.default.json"
try nrr --remove common-workers --repo "$NR"; check "modes: --remove common-workers --repo is refused even when the repo config lists it" "$RC:$(printf '%s' "$OUT" | grep -c "'common-workers' is a kit file, not a role"):$(jq '.roles | has("common-workers")' "$NR/config.default.json")" "1:1:true"
cp "$TMP/nrcd.bak" "$NR/config.default.json"
try nrm common-workers; check "modes: --remove common-workers removes a local role of that name" "$RC:$(jq '.roles | has("common-workers")' "$NRC"):$([ -e "$PK/roles/programmer/common-workers.md" ] && echo left):$(cat "$PK/prompts/programmer/common-workers.md")" "0:false::kit"
try nrm common-workers; check "modes: --remove common-workers without a local role is refused" "$RC:$(printf '%s' "$OUT" | grep -c "'common-workers' is a kit file, not a role")" "1:1"
# --help prints the header comment only
HELP="$(cd "$TMP" && HOME="$PH" "$PKL/bin/new-role.sh" --help 2>&1)"; HRC=$?
check "new-role --help: exit 0, first and last header lines, only comment lines" "$HRC:$(printf '%s\n' "$HELP" | head -1 | grep -c '^# Wizard to create a new role'):$(printf '%s\n' "$HELP" | tail -1 | grep -c '^#     Each mode has its own prompt file'):$(printf '%s\n' "$HELP" | grep -vc '^#')" "0:1:1:0"
rm -rf "$PK/config.json" "$PK/roles" "$PK/prompts/pr-reviewer"   # the kit copy is shared with other sections
}

sec_planner_skill() {
# The Planner's skill: plugin, new-role --from-json, per-worktree instructions and plugin loading
jq -e '.name == "orca-roles"' "$ROOT/plugin/.claude-plugin/plugin.json" >/dev/null && echo "ok   plugin.json valid" || { echo "FAIL plugin.json"; FAIL=1; }
check "skill: name in the frontmatter" "$(sed -n 2p "$ROOT/plugin/skills/team/SKILL.md")" "name: team"
grep -q '^## Managing the kit and the team' "$ROOT/prompts/programmer/planner.md" && echo "ok   planner.md links the skill" || { echo "FAIL planner.md without the skill"; FAIL=1; }
check "default config: the planner's plugin" "$(jq -c '.roles.planner.pluginDirs' "$ROOT/config.default.json")" '["{kit}/plugin"]'
cat > "$KIT/config.json" <<'J'
{ "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" }, "tester": { "title": "Tester" } } }
J
printf '%s' '{"id":"sec-review","description":"reviews security","model":"m-sec","params":{"maxFindings":20},"after":"dev","prompt":"# Role: SEC\n\n## Report\nx\n"}' > "$TMP/role.json"
try newrole "$TMP/role.json"; check "from-json: creates the role" "$RC" "0"
check "from-json: position after dev" "$(jq -r '.roles | keys_unsorted | join(" ")' "$KIT/config.json")" "planner dev sec-review tester"
check "from-json: fields and default title" "$(jq -c '.roles["sec-review"] | {title, description, enabled, agent, model, params}' "$KIT/config.json")" '{"title":"Sec-Review","description":"reviews security","enabled":true,"agent":"claude","model":"m-sec","params":{"maxFindings":20}}'
check "from-json: prompt in roles/<mode>/, modes programmer" "$(head -1 "$KIT/roles/programmer/sec-review.md"):$(jq -c '.roles["sec-review"] | [.modes, .prompt]' "$KIT/config.json")" "# Role: SEC:[[\"programmer\"],{\"programmer\":\"$TMP/home/.orca-roles/roles/programmer/sec-review.md\"}]"
[ -f "$KIT/config.json.bak" ] && echo "ok   from-json: .bak copy" || { echo "FAIL from-json without .bak"; FAIL=1; }
try newrole "$TMP/role.json"; check "from-json: does not overwrite without overwrite" "$RC" "1"
jq '. + {overwrite: true, model: "m2"}' "$TMP/role.json" > "$TMP/role2.json"
try newrole "$TMP/role2.json"; check "from-json: overwrite" "$RC:$(jq -r '.roles["sec-review"].model' "$KIT/config.json")" "0:m2"
printf '%s' '{"id":"cu-agent","description":"custom","agent":"custom","command":"agy {scratch}","addDirFlag":"--add-dir","trust":{"file":"~/s.json","jq":".t = [$dir]"},"clearCommand":"/new","nice":5,"pluginDirs":["{kit}/p"],"prompt":"# Role: CU\n\n## Report\nx\n"}' > "$TMP/role4.json"
try newrole "$TMP/role4.json"; check "from-json: custom keeps addDirFlag, trust, clearCommand, nice and pluginDirs" "$RC $(jq -c '.roles["cu-agent"] | [.addDirFlag, .trust, .clearCommand, .nice, .pluginDirs]' "$KIT/config.json")" '0 ["--add-dir",{"file":"~/s.json","jq":".t = [$dir]"},"/new",5,["{kit}/p"]]'
jq 'del(.roles["cu-agent"])' "$KIT/config.json" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$KIT/config.json"; rm -f "$KIT/roles/programmer/cu-agent.md"
}

sec_wizard() {
# The wizard, for a custom agent: clearCommand, addDirFlag and its extra folders (answers in order, one per line)
printf '# Role: CW\n\n## Report\nx\n' > "$TMP/cw.md"
# shellcheck disable=SC2088  # "~/a b" is what the user types; the wizard expands it
printf '%s\n' cu-wiz "" "custom wizard" "" "" custom "" "agy {scratch}" /new --add-dir "" "" "" "" n "" "~/a b" "" "" "" "" "" "" 2 "$TMP/cw.md" y > "$TMP/wiz.in"
try sh -c "cd '$TMP' && HOME='$TMP/home' NEW_ROLE_TTY='$TMP/wiz.in' '$TMP/home/.orca-roles/bin/new-role.sh' < /dev/null"
check "wizard: custom asks clearCommand, addDirFlag and extra folders" "$RC $(jq -c '.roles["cu-wiz"] | [.command, .clearCommand, .addDirFlag, .extraDirs]' "$KIT/config.json")" '0 ["agy {scratch}","/new","--add-dir",["~/a b"]]'
jq 'del(.roles["cu-wiz"])' "$KIT/config.json" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$KIT/config.json"; rm -f "$KIT/roles/programmer/cu-wiz.md"
# custom agent with model fields: the four answers after --add-dir are modelError, list, parse (only with a list) and probe
wiz_custom() {  # <id> <answers between --add-dir and the permission mode>
  local id="$1"; shift
  printf '%s\n' "$id" "" "custom wizard" "" "" custom "" "agy {scratch}" /new --add-dir "$@" "" n "" "" "" "" "" "" "" 2 "$TMP/cw.md" y > "$TMP/wiz.in"
  try sh -c "cd '$TMP' && HOME='$TMP/home' NEW_ROLE_TTY='$TMP/wiz.in' '$TMP/home/.orca-roles/bin/new-role.sh' < /dev/null 2>&1"
}
wiz_custom cu-m1 "no such model: {model}" "agy models" "json:.[]" "agy -m {model} ok"
check "wizard: custom with all four model answers" "$RC $(jq -c '.roles["cu-m1"] | [.modelError, .models]' "$KIT/config.json")" '0 ["no such model: {model}",{"list":"agy models","parse":"json:.[]","probe":"agy -m {model} ok"}]'
wiz_custom cu-m2 "" "" ""
check "wizard: custom with empty model answers has neither key" "$RC $(jq -c '.roles["cu-m2"] | [has("modelError"), has("models")]' "$KIT/config.json")" '0 [false,false]'
wiz_custom cu-m3 "" "" "agy -m {model} ok"
check "wizard: list empty but probe set gives only probe" "$RC $(jq -c '.roles["cu-m3"] | [has("modelError"), .models]' "$KIT/config.json")" '0 [false,{"probe":"agy -m {model} ok"}]'
jq 'del(.roles["cu-m1"], .roles["cu-m2"], .roles["cu-m3"])' "$KIT/config.json" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$KIT/config.json"; rm -f "$KIT/roles/programmer"/cu-m?.md
# from-json: modelError and models are copied; invalid ones stop with nothing written
printf '%s' '{"id":"fj-m","description":"x","agent":"custom","command":"c","modelError":"bad {model}","models":{"list":"l","parse":"lines","probe":"p {model}"},"prompt":"# x\n## Report\n"}' > "$TMP/role3.json"; try newrole "$TMP/role3.json"
check "from-json: modelError and models are copied" "$RC $(jq -c '.roles["fj-m"] | [.modelError, .models]' "$KIT/config.json")" '0 ["bad {model}",{"list":"l","parse":"lines","probe":"p {model}"}]'
jq 'del(.roles["fj-m"])' "$KIT/config.json" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$KIT/config.json"; rm -f "$KIT/roles/programmer/fj-m.md"
fj_snap() { { cat "$KIT/config.json"; find "$KIT/roles" -type f 2>/dev/null | sort; } | cksum; }
FJ0="$(fj_snap)"
for bad in '"models":{"probes":"x"}' '"modelError":""' '"models":{"list":""}' '"models":"x"'; do
  printf '%s' '{"id":"fj-bad","description":"x","agent":"custom","command":"c",'"$bad"',"prompt":"# x\n## Report\n"}' > "$TMP/role3.json"; try newrole "$TMP/role3.json"
  check "from-json: $bad rejected, nothing written" "$RC:$([ "$(fj_snap)" = "$FJ0" ] && echo unchanged || echo CHANGED):$(printf '%s' "$OUT" | grep -c '^ERROR')" "1:unchanged:1"
done
# wizard: an invalid parse stops before any prompt file is written; an empty parse answer takes the default "lines"
wiz_custom cu-bad "" "agy models" "bogus" ""
check "wizard: invalid parse, nothing written" "$RC:$([ "$(fj_snap)" = "$FJ0" ] && echo unchanged || echo CHANGED)" "1:unchanged"
wiz_custom cu-def "" "agy models" "" ""
check "wizard: parse defaults to lines" "$RC $(jq -c '.roles["cu-def"].models' "$KIT/config.json")" '0 {"list":"agy models","parse":"lines"}'
jq 'del(.roles["cu-def"])' "$KIT/config.json" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$KIT/config.json"; rm -f "$KIT/roles/programmer/cu-def.md"
printf '%s' '{"id":"Bad Id","description":"x","prompt":"p"}' > "$TMP/role3.json"; try newrole "$TMP/role3.json"; check "from-json: invalid id" "$RC" "1"
printf '%s' '{"id":"no-desc","prompt":"p"}' > "$TMP/role3.json"; try newrole "$TMP/role3.json"; check "from-json: without description" "$RC" "1"
printf '%s' '{"id":"planner","description":"x","prompt":"p"}' > "$TMP/role3.json"; try newrole "$TMP/role3.json"; check "from-json: planner reserved" "$RC" "1"
}

sec_role_notes() {
# A role's instructions for this worktree only, inside its role message
N="$TMP/nproj"; mkdir -p "$N"; git -C "$N" init -q; mkdir -p "$N/.git/orca-roles.notes"
printf 'Use pnpm.\nDo not touch the legacy folder.\n' > "$N/.git/orca-roles.notes/dev.md"
case "$(cd "$N" && worker_msg "$KIT/config.json" dev)" in *"Additional instructions for this worktree, which take precedence over your prompt if they conflict: Use pnpm. Do not touch the legacy folder." ) echo "ok   worker_msg includes the worktree's instructions";; *) echo "FAIL worker_msg notes: $(cd "$N" && worker_msg "$KIT/config.json" dev)"; FAIL=1;; esac
case "$(cd "$N" && worker_msg "$KIT/config.json" tester)" in *"Additional instructions"*) echo "FAIL worker_msg: notes in a role without notes"; FAIL=1;; *) echo "ok   worker_msg without notes adds nothing";; esac
}

sec_plugin_dirs() {
# agent.sh passes the plugin and the extra folders with ~ and {kit} expanded
cat > "$KIT/config.json" <<'J'
{ "defaults": { "mcp": [] }, "mcpServers": {}, "roles": { "planner": { "agent": "claude", "mcp": "all", "extraDirs": ["{kit}", "~/x"], "pluginDirs": ["{kit}/plugin"] } } }
J
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$TMP/fakebin/claude"; chmod +x "$TMP/fakebin/claude"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" planner | tr '\n' ' ')"
case "$OUT" in *"--add-dir $TMP/home/.orca-roles --add-dir $TMP/home/x --plugin-dir $TMP/home/.orca-roles/plugin "*) echo "ok   agent.sh: --plugin-dir and --add-dir expanded";; *) echo "FAIL agent.sh plugin: $OUT"; FAIL=1;; esac
case "$OUT" in *'"language":"english"'*) echo "FAIL agent.sh: the Planner got the English language override"; FAIL=1;; *) echo "ok   agent.sh: the Planner keeps the user's language (no --settings override)";; esac
rm -f "$TMP/fakebin/claude"
}

sec_composer_session() {
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
}

sec_orca_alias() {
cli_shim_dir
# The 'orca' alias the installer adds to ~/.bashrc: points to $ORCA_CLI_COMMAND in Orca's WSL terminals, nothing elsewhere
ALIAS_LINE="$(grep 'orca-roles: orca alias' "$ROOT/install.sh" | sed -e "s/^grep -q 'orca-roles: orca alias' \"\$RC\" 2>\/dev\/null || echo '//" -e "s/' >> \"\$RC\"\$//")"
check "orca alias: calls ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide bash -c "shopt -s expand_aliases; $ALIAS_LINE
orca worktree list")" "orca-ide:worktree list"
check "orca alias: nothing outside Orca" "$(PATH="/usr/bin:/bin" ORCA_CLI_COMMAND='' bash -c "shopt -s expand_aliases; $ALIAS_LINE
command -v orca || echo none")" "none"
}

sec_remove_role() {
# Removing a role: new-role --remove (only roles you created) and close-role.sh (closes its tab in this workspace)
cat > "$KIT/config.json" <<'J'
{ "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" } } }
J
printf '%s' '{"id":"sec-review","description":"reviews security","prompt":"# Role: SEC\n\n## Report\nx\n"}' > "$TMP/role.json"
newrole "$TMP/role.json" >/dev/null
rmrole() { (cd "$TMP" && HOME="$TMP/home" "$TMP/home/.orca-roles/bin/new-role.sh" --remove "$1" 2>&1); }
try rmrole sec-review; check "remove: a role you created" "$RC:$(jq -r '.roles | keys_unsorted | join(" ")' "$KIT/config.json"):$([ -f "$KIT/roles/programmer/sec-review.md" ] && echo prompt-left || echo prompt-gone)" "0:planner dev:prompt-gone"
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
}

sec_prompts_misc() {
# The Planner does not block waiting for the workers
grep -q 'Never block waiting for the workers' "$ROOT/prompts/programmer/planner.md" && ! grep -q 'check --wait --types' "$ROOT/prompts/programmer/planner.md" && echo "ok   planner.md: waits without blocking" || { echo "FAIL planner.md still blocks in check --wait"; FAIL=1; }

# The repo is a Claude Code marketplace whose plugin is the kit's own
check "marketplace: lists the orca-roles plugin from ./plugin" "$(jq -r '.plugins[] | "\(.name) \(.source)"' "$ROOT/.claude-plugin/marketplace.json")" "orca-roles ./plugin"
check "marketplace: same name as the plugin" "$(jq -r '.plugins[0].name' "$ROOT/.claude-plugin/marketplace.json")" "$(jq -r '.name' "$ROOT/plugin/.claude-plugin/plugin.json")"
grep -q '^## Start here' "$ROOT/README.md" && [ "$(grep -n '^## ' "$ROOT/README.md" | head -1 | cut -d: -f2-)" = "## Start here: get Claude's help with the setup" ] && echo "ok   README starts with installing the guide" || { echo "FAIL README does not start with the guide"; FAIL=1; }

# Tighter steps: the rules from the review are in the prompts and the defaults
for pat in 'Scope: only what the user asked' 'Criteria as families with boundaries' 'Threat model and rejection threshold' 'Check the libraries first' 'contract decision' 'Fix rounds carry only what changed' 'do not try Jira'"'"'s REST API'; do
  grep -q "$pat" "$ROOT/prompts/programmer/planner.md" || { echo "FAIL planner.md without: $pat"; FAIL=1; }
done
grep -q 'maxSelfMutants' "$ROOT/prompts/programmer/tester.md" && grep -q 'family of inputs with its boundaries' "$ROOT/prompts/programmer/tester.md" || { echo "FAIL tester.md without self-mutation or families"; FAIL=1; }
grep -q 'Reject only from the threshold' "$ROOT/prompts/programmer/auditor.md" && grep -q 'rejectSeverity' "$ROOT/prompts/programmer/auditor.md" || { echo "FAIL auditor.md without the threshold"; FAIL=1; }
grep -q 'family with its boundaries' "$ROOT/prompts/programmer/dev.md" || { echo "FAIL dev.md without boundaries"; FAIL=1; }
check "defaults: Tester maxSelfMutants and Auditor rejectSeverity" "$(jq -c '[.roles.tester.params.maxSelfMutants, .roles.auditor.params.rejectSeverity]' "$ROOT/config.default.json")" '[3,"high"]'
echo "ok   prompts carry the review's rules"
}

sec_composer_tab() {
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
}

sec_dead_tab() {
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
for r in cu tst; do : > "$KIT/prompts/programmer/$r.md"; done   # fake roles need a prompt file to be launched (removed at the end of the section)
OUT="$(cd "$DP" && HOME="$TMP/home" PATH="$TMP/dbin:$PATH" ORCA_ROLES_AGENT_CHECKS=1 "$TMP/home/.orca-roles/bin/launch.sh" 2>&1)"
case "$OUT" in *"The agent in the tab of Dev (t-dev) is gone"*) echo "ok   dead agent: detected in a live tab";; *) echo "FAIL dead agent: $OUT"; FAIL=1;; esac
check "dead agent: its old tab is closed" "$(grep -c 'terminal close --terminal t-dev --tab' "$DLOG")" "1"
check "dead agent: a new tab replaces it" "$(cut -d= -f2 "$DP/.git/orca-roles.env" | tr '\n' ' ')" "t-pl h-Dev t-cu h-Tst "
check "dead agent: custom agents are not checked" "$(grep -c 'terminal close --terminal t-cu' "$DLOG" || true)" "0"
case "$OUT" in *"The tab of Tst (t-orp) was closed but Orca kept its session running"*) echo "ok   orphaned session: detected";; *) echo "FAIL orphaned: $OUT"; FAIL=1;; esac
check "orphaned session: ended" "$(grep -c 'terminal close --terminal t-orp' "$DLOG")" "1"
check "E1: non-Claude workers run Orca's commands in the foreground" "$(worker_msg "$KIT/config.json" cu | grep -c 'in the foreground')" "1"
check "E1: Claude workers get no extra instruction" "$(worker_msg "$KIT/config.json" dev | grep -c 'in the foreground' || true)" "0"
grep -q 'Watch for silent workers' "$ROOT/prompts/programmer/planner.md" && echo "ok   G: the Planner watches for silent workers" || { echo "FAIL planner.md without silent workers"; FAIL=1; }
rm -f "$KIT/prompts/programmer/cu.md" "$KIT/prompts/programmer/tst.md"
}

sec_agent_flags() {
# Jira/GitHub only with the user's yes; resource caps for the Tester and the Auditor
grep -q "Nothing leaves the worktree without the user's explicit yes" "$ROOT/prompts/programmer/planner.md" && echo "ok   planner.md: Jira/GitHub only with approval" || { echo "FAIL planner.md: approval rule"; FAIL=1; }
grep -q 'Never write to Jira, GitHub' "$ROOT/prompts/programmer/common-workers.md" && echo "ok   common-workers.md: workers never write to Jira/GitHub" || { echo "FAIL common-workers.md: Jira/GitHub rule"; FAIL=1; }
grep -q '^## Coming back with your memory' "$ROOT/prompts/programmer/planner.md" && echo "ok   planner.md: coming back with memory" || { echo "FAIL planner.md: memory section"; FAIL=1; }
for r in tester auditor; do grep -q 'No GPU' "$ROOT/prompts/programmer/$r.md" && grep -q 'maxWorkers' "$ROOT/prompts/programmer/$r.md" || { echo "FAIL $r.md: resource caps"; FAIL=1; }; done; echo "ok   tester/auditor prompts: CPU, threads and GPU caps"
check "default config: tester and auditor lowered priority" "$(jq -r '[.roles.tester.nice, .roles.auditor.nice] | join(",")' "$ROOT/config.default.json")" "10,10"
check "default config: thread caps and no GPU" "$(jq -r '.roles.auditor.env | [.OMP_NUM_THREADS, .GOMAXPROCS, .CUDA_VISIBLE_DEVICES] | join("|")' "$ROOT/config.default.json")" "2|2|"
check "default config: auditor maxWorkers" "$(jq -r '.roles.auditor.params.maxWorkers' "$ROOT/config.default.json")" "2"
# agent.sh: nice -n and --resume
cat > "$KIT/config.json" <<'J'
{ "defaults": { "mcp": "all", "agent": "claude" }, "mcpServers": {}, "roles": { "tester": { "nice": 10, "env": { "GOMAXPROCS": "2" } }, "dev": {}, "planner": {}, "tx": { "extraArgs": ["--settings", "{\"language\":\"spanish\"}"] }, "cx": { "agent": "codex" } } }
J
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$TMP/fakebin/claude"; cp "$TMP/fakebin/claude" "$TMP/fakebin/codex"; chmod +x "$TMP/fakebin/claude" "$TMP/fakebin/codex"
printf '#!/bin/sh\nprintf "nice %%s %%s\\n" "$1" "$2"; shift 2; echo "GOMAXPROCS=$GOMAXPROCS"; exec "$@"\n' > "$TMP/fakebin/nice"; chmod +x "$TMP/fakebin/nice"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" tester | tr '\n' ' ')"
case "$OUT" in "nice -n 10 GOMAXPROCS=2 --add-dir "*) echo "ok   agent.sh: nice -n and the role's env";; *) echo "FAIL agent.sh nice: $OUT"; FAIL=1;; esac
case "$OUT" in *'--settings {"language":"english"} '*) echo "ok   agent.sh: claude workers launch with the English language setting";; *) echo "FAIL agent.sh worker without the English setting: $OUT"; FAIL=1;; esac
case "$OUT" in *'Always write in English'*) echo "ok   agent.sh: the worker's system prompt carries the English rule";; *) echo "FAIL agent.sh worker anchor without the English rule: $OUT"; FAIL=1;; esac
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" tx | tr '\n' ' ')"
case "$OUT" in *'--settings {"language":"english"} --settings {"language":"spanish"} '*) echo "ok   agent.sh: a role's own --settings in extraArgs comes after (and wins over) the English one";; *) echo "FAIL agent.sh extraArgs --settings order: $OUT"; FAIL=1;; esac
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" planner | tr '\n' ' ')"
case "$OUT" in *--settings*|*'Always write in English'*) echo "FAIL agent.sh: the Planner got the English setting or rule: $OUT"; FAIL=1;; *) echo "ok   agent.sh: the Planner gets neither --settings nor the English rule";; esac
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
case "$OUT" in *"--add-dir $(cd "$TMP" && KIT="$TMP/home/.orca-roles" scratch_dir cx) "*) echo "ok   agent.sh codex: --add-dir <scratch>";; *) echo "FAIL agent.sh codex scratch: $OUT"; FAIL=1;; esac
case "$OUT" in (*--append-system-prompt*) echo "FAIL agent.sh codex got claude's flag: $OUT"; FAIL=1;; (*) echo "ok   agent.sh codex: not claude's flag";; esac
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" tester)"
CFGT="$KIT/config.json"   # role_anchor runs with the kit seen from the fake HOME
check "agent.sh claude: one line in the system prompt that asks for the role after /clear" "$(printf '%s\n' "$OUT" | grep -A1 -x -- --append-system-prompt | tail -1)" "$(KIT="$TMP/home/.orca-roles" role_anchor "$CFGT" tester)"
case "$(KIT="$TMP/home/.orca-roles" role_anchor "$CFGT" tester)" in (*"after /clear"*"$TMP/home/.orca-roles/bin/clean.sh --msg tester"*) echo "ok   role_anchor: names the role and the command";; (*) echo "FAIL role_anchor"; FAIL=1;; esac
check "agent.sh leaves pre-seeded scratch content intact" "$([ -f "$SDT/f" ] && [ -f "$SDT/sub/g" ] && [ -f "$SDT/.hidden" ] && echo y)" "y"
rm -f "$TMP/fakebin/claude" "$TMP/fakebin/codex" "$TMP/fakebin/nice"
}

sec_restart() {
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
: > "$KIT/prompts/programmer/tst.md"   # removed at the end of the section
# the mode cannot change under a team Orca restored after a restart (new handles, same ptyId)
mkdir -p "$KIT/prompts/pr-reviewer"; : > "$KIT/prompts/pr-reviewer/planner.md"; cp "$KIT/config.json" "$RP/.git/orca-roles.config.json"
HB="$(cat "$RP/.git/orca-roles.env" "$RP/.git/orca-roles.pty" "$RP/.git/orca-roles.config.json" | cksum)"; : > "$RLOG"
OUT="$(cd "$RP" && HOME="$TMP/home" PATH="$TMP/rbin:$PATH" ORCA_ROLES_AGENT_CHECKS=1 ORCA_ROLES_KICKOFF="$TMP/rbin/kickoff" "$TMP/home/.orca-roles/bin/launch.sh" --mode pr-reviewer 2>&1)" && RC=0 || RC=$?
check "restart: restored tabs block a mode change; nothing saved, closed or opened" "$RC:$(grep -cE 'terminal (close|create)' "$RLOG" || true):$(cat "$RP/.git/orca-roles.env" "$RP/.git/orca-roles.pty" "$RP/.git/orca-roles.config.json" | cksum):$([ -e "$RP/.git/orca-roles.overrides.json" ] && echo ovr)" "1:0:$HB:"
case "$OUT" in *"Close the team first"*) echo "ok   restart: the mode change error explains it";; *) echo "FAIL restart mode change: $OUT"; FAIL=1;; esac
rm -rf "$KIT/prompts/pr-reviewer"; rm -f "$RP/.git/orca-roles.config.json"
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
rm -f "$KIT/prompts/programmer/tst.md"
}

sec_trust_folder() {
# trust_folder: edits ~/.claude.json without widening its mode, keeping links, losing concurrent writes or leaving files behind
tf_setup
# 1. C1: the mode never widens (family of modes)
for m in 600 640 644 400 664 755; do
  H="$TF/h-m$m"; mkdir -p "$H"; echo "$TFJ" > "$H/.claude.json"; chmod "$m" "$H/.claude.json"; tf_run "$H"
  check "trust_folder: mode $m kept" "$(file_mode_of "$H/.claude.json") $(tf_trusted "$H/.claude.json") $(jq -c .oauthAccount "$H/.claude.json") $(jq -r '.projects["/other"].hasTrustDialogAccepted' "$H/.claude.json")" "$m true {\"email\":\"a@b\"} true"
done
# 2. C1: while the temp exists it is never wider than the original
for m in 600 640 400; do
  H="$TF/h-t$m"; mkdir -p "$H"; echo "$TFJ" > "$H/.claude.json"; chmod "$m" "$H/.claude.json"
  tf_run "$H" "stat -c %a '$H'/.claude.json.orca-roles.* > '$TF/tmpmode' 2>/dev/null || stat -f %Lp '$H'/.claude.json.orca-roles.* > '$TF/tmpmode'"
  check "trust_folder: temp mode while it exists ($m)" "$(cat "$TF/tmpmode")" "$m"
done
# 3. C2: links are kept and their final target is the one edited
H="$TF/h-l"; mkdir -p "$H/real" "$H/sub" "$H/o"
echo "$TFJ" > "$H/real/c.json"; chmod 640 "$H/real/c.json"
ln -s "$H/real/c.json" "$H/.claude.json"; tf_run "$H"
check "trust_folder: absolute link kept" "$(readlink "$H/.claude.json") $(tf_trusted "$H/real/c.json") $(file_mode_of "$H/real/c.json")" "$H/real/c.json true 640"
rm "$H/.claude.json"; echo "$TFJ" > "$H/real/c.json"; ln -s real/c.json "$H/.claude.json"; tf_run "$H"
check "trust_folder: relative link kept" "$(readlink "$H/.claude.json") $(tf_trusted "$H/real/c.json")" "real/c.json true"
rm "$H/.claude.json"; echo "$TFJ" > "$H/real/c.json"; ln -s ../real/c.json "$H/o/a"; ln -s o/a "$H/.claude.json"; tf_run "$H"
check "trust_folder: chain of links kept" "$(readlink "$H/.claude.json") $(readlink "$H/o/a") $(tf_trusted "$H/real/c.json") $([ -L "$H/real/c.json" ] && echo link || echo file)" "o/a ../real/c.json true file"
rm "$H/.claude.json"; echo "$TFJ" > "$H/sub/x.json"; ln -s ../sub/x.json "$H/o/b"; ln -s o/b "$H/.claude.json"; tf_run "$H"
check "trust_folder: link into another folder kept" "$(readlink "$H/.claude.json") $(readlink "$H/o/b") $(tf_trusted "$H/sub/x.json") $(tf_left "$H/sub")" "o/b ../sub/x.json true 0"
# 4. C2: dangling link -> nothing created
H="$TF/h-d"; mkdir -p "$H"; ln -s "$H/nowhere.json" "$H/.claude.json"; tf_run "$H"
check "trust_folder: dangling link, nothing created, silent, no lock" "$(cat "$TF/rc") $([ -e "$H/nowhere.json" ] && echo created || echo none) $([ -L "$H/.claude.json" ] && echo link) $(ls -A "$H" | tr '\n' ' ') [$(cat "$TF/err" "$TF/out")]" "0 none link .claude.json  []"
H="$TF/h-dir"; mkdir -p "$H/.claude.json"; tf_run "$H"
check "trust_folder: a directory instead of the file, silent, no lock" "$(cat "$TF/rc") $(ls -A "$H" | tr '\n' ' ') $(ls -A "$H/.claude.json" | wc -l | tr -d ' ') [$(cat "$TF/err" "$TF/out")]" "0 .claude.json  0 []"
# 5. C3: file changed once during our write -> both changes survive
H="$TF/h-c1"; mkdir -p "$H"; echo "$TFJ" > "$H/.claude.json"; chmod 600 "$H/.claude.json"
HK="[ -e '$H/seen' ] || { touch '$H/seen'; jq '.x=1' '$H/.claude.json' > '$H/w' && cat '$H/w' > '$H/.claude.json'; }"
tf_run "$H" "$HK"
check "trust_folder: change during the write is not lost" "$(jq -r .x "$H/.claude.json") $(tf_trusted "$H/.claude.json") $(jq -c .oauthAccount "$H/.claude.json") $(cat "$TF/rc") $(tf_left "$H") $(file_mode_of "$H/.claude.json")" "1 true {\"email\":\"a@b\"} 0 0 600"
# 6. C3: file changes on every attempt -> left exactly as the other writer left it, with a warning
H="$TF/h-c2"; mkdir -p "$H"; echo "$TFJ" > "$H/.claude.json"
tf_run "$H" "n=\$(cat '$H/n' 2>/dev/null || echo 0); echo \$((n+1)) > '$H/n'; jq --argjson n \$n '.x=\$n' '$H/.claude.json' > '$H/w' && cat '$H/w' > '$H/.claude.json'"
check "trust_folder: constant change -> untouched, warning" "$(jq -r .x "$H/.claude.json") $(tf_trusted "$H/.claude.json") $(grep -c '^Warning' "$TF/err") $(cat "$TF/rc") $(tf_left "$H") $([ -d "$H/.claude.json.lock" ] && echo lock)" "1 false 1 0 0 "
# 7. C4: failures are clean (invalid JSON, unreadable file, unwritable target folder)
H="$TF/h-f1"; mkdir -p "$H"; printf '{ not json' > "$H/.claude.json"; cp "$H/.claude.json" "$TF/orig1"; tf_run "$H"
check "trust_folder: invalid JSON untouched" "$(cmp -s "$H/.claude.json" "$TF/orig1" && echo same) $(grep -c '^Warning' "$TF/err") $(cat "$TF/rc") $(ls -A "$H" | tr '\n' ' ')" "same 1 0 .claude.json "
if [ "$(id -u)" != 0 ]; then
  H="$TF/h-f2"; mkdir -p "$H"; echo "$TFJ" > "$H/.claude.json"; chmod 000 "$H/.claude.json"; tf_run "$H"; chmod 600 "$H/.claude.json"
  check "trust_folder: unreadable file untouched, one warning, rc 0, clean" "$(grep -c '^Warning' "$TF/err") $(cat "$TF/rc") $(ls -A "$H" | tr '\n' ' ') $(echo "$TFJ" | cmp -s - "$H/.claude.json" && echo same)" "1 0 .claude.json  same"
  H="$TF/h-f3"; mkdir -p "$H/ro"; echo "$TFJ" > "$H/ro/c.json"; ln -s ro/c.json "$H/.claude.json"; cp "$H/ro/c.json" "$TF/orig3"; chmod 500 "$H/ro"; tf_run "$H"; chmod 700 "$H/ro"
  check "trust_folder: unwritable folder untouched, one warning, rc 0, clean" "$(cmp -s "$H/ro/c.json" "$TF/orig3" && echo same) $(grep -c '^Warning' "$TF/err") $(cat "$TF/rc") $(tf_left "$H/ro") $(tf_left "$H")" "same 1 0 0 0"
else echo "ok   trust_folder: unreadable/unwritable cases skipped (root)"; fi
# 8. C4: a foreign lock is waited for, never removed; the write still happens
H="$TF/h-lk"; mkdir -p "$H/.claude.json.lock"; echo "$TFJ" > "$H/.claude.json"; chmod 600 "$H/.claude.json"; tf_run "$H"
check "trust_folder: foreign lock waited for and kept" "$(tf_trusted "$H/.claude.json") $([ -d "$H/.claude.json.lock" ] && echo lock-kept) $(cat "$TF/rc") $(tf_left "$H")" "true lock-kept 0 0"
# 9. C4/C5: our lock is removed; no-op cases
H="$TF/h-n"; mkdir -p "$H"; echo "$TFJ" > "$H/.claude.json"; tf_run "$H"
LK1="$([ -d "$H/.claude.json.lock" ] && echo lock || echo nolock)"
ino="$(ls -i "$H/.claude.json" | cut -d' ' -f1)"; mt="$(stat -c %Y "$H/.claude.json" 2>/dev/null || stat -f %m "$H/.claude.json")"; sleep 1.1
tf_run "$H"; ino2="$(ls -i "$H/.claude.json" | cut -d' ' -f1)"; mt2="$(stat -c %Y "$H/.claude.json" 2>/dev/null || stat -f %m "$H/.claude.json")"
H0="$TF/h-none"; mkdir -p "$H0"; tf_run "$H0"
check "trust_folder: our lock removed, already trusted not rewritten, missing file not created" "$LK1 $([ "$ino" = "$ino2" ] && [ "$mt" = "$mt2" ] && echo same) $(ls -A "$H0" | wc -l | tr -d ' ') $(cat "$TF/rc") $(wc -c <"$TF/out" | tr -d ' ')" "nolock same 0 0 0"
# 10. C5/C6: launch.sh still gates on claude and survives a warning; the new code stays portable
check "trust_folder: launch.sh calls it only when a role uses claude" "$(grep -c 'trust_folder' "$ROOT/bin/launch.sh") $(grep -B3 'trust_folder' "$ROOT/bin/launch.sh" | grep -c claude)" "1 1"
TFCODE="$(sed -n '/^resolve_target()/,/^  exit 0$/p' "$ROOT/bin/lib.sh" | grep -v '^ *#')"
check "trust_folder: no readlink -f / chmod --reference" "$(printf '%s\n' "$TFCODE" | grep -c 'readlink -f\|chmod --reference')" "0"
check "trust_folder: every GNU stat has the BSD fallback" "$(printf '%s\n' "$TFCODE" | grep 'stat -c' | grep -vc 'stat -f')" "0"

# safe_json_edit step 2: physical resolution, temp mode on every try, lock path, temp location
# 11. (T1) HOME is a symlinked folder and ~/.claude.json -> ../shared/c.json: the physical target is edited, the decoy at the logical path is not
mkdir -p "$TF/phys/home" "$TF/phys/shared" "$TF/shared"; ln -sfn phys/home "$TF/hl"
echo "$TFJ" > "$TF/phys/shared/c.json"; echo '{"decoy":true}' > "$TF/shared/c.json"; ln -sf ../shared/c.json "$TF/phys/home/.claude.json"
tf_run "$TF/hl"
check "trust_folder: symlinked HOME, physical target edited, decoy untouched" "$(tf_trusted "$TF/phys/shared/c.json") $(cat "$TF/shared/c.json") $(readlink "$TF/phys/home/.claude.json") $(tf_left "$TF/shared") $(tf_left "$TF/phys/shared") $(cat "$TF/rc")" 'true {"decoy":true} ../shared/c.json 0 0 0'
# 12. (T2/T4) the temp is 0600-or-original mode at every try (a restrictive original must not break the retry), and lives in the target's folder
for m in 400 440 600 640; do
  H="$TF/h-r$m"; mkdir -p "$H/real"; echo "$TFJ" > "$H/real/c.json"; chmod "$m" "$H/real/c.json"; ln -s real/c.json "$H/.claude.json"
  tf_run "$H" "for t in '$H'/real/.c.json.orca-roles.*; do echo \$(stat -c %a \"\$t\" 2>/dev/null || stat -f %Lp \"\$t\") >> '$H/modes'; done; ls '$H'/.c* '$H'/.claude.json.orca-roles.* >/dev/null 2>&1 && echo in-home >> '$H/modes'; [ -e '$H/seen' ] || { touch '$H/seen'; chmod u+w '$H/real/c.json'; jq '.x=1' '$H/real/c.json' > '$H/w' && cat '$H/w' > '$H/real/c.json'; chmod $m '$H/real/c.json'; }"
  check "trust_folder: temp mode on both tries and in the target's folder ($m)" "$(tr '\n' ' ' < "$H/modes") $(jq -r .x "$H/real/c.json") $(tf_trusted "$H/real/c.json") $(file_mode_of "$H/real/c.json") $(tf_left "$H/real") $(tf_left "$H")" "$m $m  1 true $m 0 0"
done
# 13. (T3) the lock is the LINK's path (~/.claude.json.lock), never the target's; ours is gone afterwards
H="$TF/h-lp"; mkdir -p "$H/real"; echo "$TFJ" > "$H/real/c.json"; ln -s real/c.json "$H/.claude.json"
tf_run "$H" "[ -d '$H/.claude.json.lock' ] && echo link-lock >> '$H/seen'; [ -e '$H/real/c.json.lock' ] && echo target-lock >> '$H/seen'; true"
check "trust_folder: lock taken at the link's path, not the target's, and removed" "$(cat "$H/seen") $(tf_trusted "$H/real/c.json") $(ls -A "$H" | tr '\n' ' ') $(ls -A "$H/real" | tr '\n' ' ')" "link-lock true .claude.json real seen  c.json "
H="$TF/h-lq"; mkdir -p "$H/real" "$H/.claude.json.lock"; echo "$TFJ" > "$H/real/c.json"; ln -s real/c.json "$H/.claude.json"; tf_run "$H"
check "trust_folder: foreign lock at the link's path kept (link target)" "$(tf_trusted "$H/real/c.json") $([ -d "$H/.claude.json.lock" ] && echo kept) $([ -e "$H/real/c.json.lock" ] && echo target-lock)" "true kept "
}

sec_codex_custom() {
tf_setup
# codex / custom agents: argv through fake executables
FB2="$TMP/fb2"; mkdir -p "$FB2"
printf '#!/bin/bash\nfor a in "$@"; do printf "%%s\\0" "$a"; done > "%s/argv"\n' "$FB2" > "$FB2/codex"
printf '#!/bin/sh\n[ "$1" = -lc ] && { echo "$2"; echo "ENV=$ORCA_ROLES_SCRATCH"; exit 0; }\nexec /bin/bash "$@"\n' > "$FB2/bash"; chmod +x "$FB2/codex" "$FB2/bash"
cat > "$TMP/cfg2.json" <<'J'
{ "defaults": {}, "mcpServers": { "pw": { "command": "npx", "args": ["-y", "x"] } },
  "roles": {
    "cxa": { "agent": "codex", "permissionMode": "auto", "mcp": ["pw"], "extraDirs": ["~/a b", "{kit}/z", "/c"] },
    "cxn": { "agent": "codex", "permissionMode": "acceptEdits", "mcp": "all" },
    "cs": { "agent": "custom", "command": "run {scratch} --s", "mcp": "all", "addDirFlag": "--add-dir", "extraDirs": ["~/a b", "/c"] },
    "cp": { "agent": "custom", "command": "run {scratch}", "mcp": "all", "extraDirs": ["/c"] },
    "cn": { "agent": "custom", "command": "run --x", "mcp": "all", "extraDirs": ["/c"] },
    "ca": { "agent": "custom", "command": "run {anchor}", "mcp": "all" } } }
J
agent2() { (cd "$WT2" && HOME="$TMP/home" PATH="$FB2:$PATH" ORCA_ROLES_CONFIG="$TMP/cfg2.json" "$TMP/home/.orca-roles/bin/agent.sh" "$@" 2>&1); }
tomlkey() { python3 -c 'import sys,tomllib; d=tomllib.loads(sys.argv[1]); print(*d["projects"])' "$1" 2>/dev/null; }
WT2="$TMP/w t.x\"q"; mkdir -p "$WT2"; WT2P="$(cd "$WT2" && pwd -P)"
SD2="$(cd "$WT2" && KIT="$TMP/home/.orca-roles" scratch_dir cxa)"
# 14. (S1/S2/S3) codex auto: sandbox flags, no --full-auto, add-dir per element, one trust override (parses as TOML), MCP overrides kept
agent2 cxa >/dev/null; CA=(); while IFS= read -r -d '' a; do CA+=("$a"); done < "$FB2/argv"; J="|$(IFS='|'; echo "${CA[*]}")|"
check "codex auto: --sandbox workspace-write --ask-for-approval on-request, no --full-auto" "$(case "$J" in (*'|--sandbox|workspace-write|--ask-for-approval|on-request|'*) echo flags;; esac)$(case "$J" in (*full-auto*) echo FULL;; esac)" "flags"
check "codex auto: --add-dir scratch + each extraDir as one element, expanded" "$(case "$J" in (*"|--add-dir|$SD2|--add-dir|$TMP/home/a b|--add-dir|$TMP/home/.orca-roles/z|--add-dir|/c|"*) echo ok;; esac) $([ -d "$SD2" ] && echo exists)" "ok exists"
NP=0; TV=""; for a in "${CA[@]}"; do case "$a" in projects=*) NP=$((NP+1)); TV="$a";; esac; done
check "codex auto: exactly one projects override, with -c before it, key = physical worktree (spaces, dot, quote)" "$NP $(for i in "${!CA[@]}"; do [ "${CA[$i]}" = "$TV" ] && echo "${CA[$((i-1))]}"; done) $(tomlkey "$TV" | cmp -s - <(printf '%s\n' "$WT2P") && echo key-ok) $(case "$TV" in (*'{trust_level = "trusted"}}') echo trusted;; esac)" "1 -c key-ok trusted"
check "codex auto: MCP -c overrides still present" "$(case "$J" in (*'|-c|mcp_servers.pw.command="npx"|-c|'*) echo ok;; esac)" "ok"
# 15. (S1/S3) codex non-auto: no sandbox / approval / full-auto, still scratch + one trust override
agent2 cxn >/dev/null; CN=(); while IFS= read -r -d '' a; do CN+=("$a"); done < "$FB2/argv"; J="|$(IFS='|'; echo "${CN[*]}")|"
NP=0; for a in "${CN[@]}"; do case "$a" in projects=*) NP=$((NP+1));; esac; done
check "codex non-auto: no --sandbox/--ask-for-approval/--full-auto; scratch and one trust" "$(case "$J" in (*--sandbox*|*--ask-for-approval*|*full-auto*) echo BAD;; (*) echo clean;; esac) $(case "$J" in (*"|--add-dir|$(cd "$WT2" && KIT="$TMP/home/.orca-roles" scratch_dir cxn)|"*) echo scratch;; esac) $NP" "clean scratch 1"
# The anchor that makes a role ask for its role again after its conversation is cleared: codex as developer_instructions (one
# override that parses as TOML to the exact line), custom through {anchor} and $ORCA_ROLES_ANCHOR
agent2 cxa >/dev/null; DI="$(tr '\0' '\n' < "$FB2/argv" | grep '^developer_instructions=')"; ANC="$(cd "$WT2" && KIT="$TMP/home/.orca-roles" role_anchor "$TMP/cfg2.json" cxa)"
check "codex: developer_instructions is the anchor, once, after -c" "$(printf '%s\n' "$DI" | grep -c .) $(tr '\0' '\n' < "$FB2/argv" | grep -B1 -x -- "$DI" | head -1) $(python3 -c 'import sys,tomllib; print(tomllib.loads(sys.argv[1])["developer_instructions"] == sys.argv[2])' "$DI" "$ANC")" "1 -c True"
ANC="$(cd "$WT2" && KIT="$TMP/home/.orca-roles" role_anchor "$TMP/cfg2.json" ca)"
case "$DI" in *'Always write in English'*) echo "ok   codex: developer_instructions carries the English rule";; *) echo "FAIL codex developer_instructions without the English rule: $DI"; FAIL=1;; esac
case "$ANC" in *'Always write in English'*) echo "ok   custom: the anchor carries the English rule";; *) echo "FAIL custom anchor without the English rule: $ANC"; FAIL=1;; esac
check "custom: {anchor} is the quoted anchor" "$(agent2 ca | head -1)" "run $(printf '%q' "$ANC")"
(cd "$WT2" && HOME="$TMP/home" ORCA_ROLES_CONFIG="$TMP/cfg2.json" bash -c '. "$HOME/.orca-roles/bin/lib.sh"; jq '"'"'.roles.ca.command = "printf %s \"$ORCA_ROLES_ANCHOR\" > anchor.out"'"'"' "$ORCA_ROLES_CONFIG" > cfg-a.json' && HOME="$TMP/home" ORCA_ROLES_CONFIG="$WT2/cfg-a.json" "$TMP/home/.orca-roles/bin/agent.sh" ca >/dev/null 2>&1)
check "custom: \$ORCA_ROLES_ANCHOR in the agent's environment" "$(cat "$WT2/anchor.out" 2>/dev/null)" "$ANC"
rm -f "$WT2/cfg-a.json" "$WT2/anchor.out"
# 16. (S4/S5) custom: {scratch} quoted, ORCA_ROLES_SCRATCH exported, addDirFlag appends flag+scratch and flag+each extraDir; without addDirFlag nothing appended
SDS="$(cd "$WT2" && KIT="$TMP/home/.orca-roles" scratch_dir cs)"; QS="$(printf '%q' "$SDS")"
OUT="$(agent2 cs)"
check "custom: {scratch} quoted, env set, addDirFlag appends scratch and extraDirs quoted" "$OUT" "run $QS --s --add-dir $QS --add-dir $(printf '%q' "$TMP/home/a b") --add-dir /c
ENV=$SDS"
SDP="$(cd "$WT2" && KIT="$TMP/home/.orca-roles" scratch_dir cp)"
check "custom: no addDirFlag, extraDirs/trust absent -> exactly as before" "$(agent2 cp | head -1) | $(agent2 cn | head -1)" "run $(printf '%q' "$SDP") | run --x"

# custom trust (trust {file, jq}) through trust_custom_roles
tc_run() { # <home> <roles json> <role ids> [hook]: stdout -> $TF/out, stderr -> $TF/err, rc -> $TF/rc
  jq -n --argjson r "$2" '{defaults:{},mcpServers:{},roles:$r}' > "$TF/tcfg.json"
  (cd "$TF/wt" && HOME="$1" ORCA_ROLES_TRUST_HOOK="${4:-}" trust_custom_roles "$TF/tcfg.json" "$3" >"$TF/out" 2>"$TF/err"; echo $? >"$TF/rc") || true
}
TCF='.t[$dir] = true'
TR1="{\"a\":{\"agent\":\"custom\",\"command\":\"x\",\"trust\":{\"file\":\"~/cust.json\",\"jq\":$(jq -Rn --arg f "$TCF" '$f')}},\"b\":{\"agent\":\"custom\",\"command\":\"x\",\"trust\":{\"file\":\"~/cust.json\",\"jq\":$(jq -Rn --arg f "$TCF" '$f')}},\"c\":{\"agent\":\"claude\",\"trust\":{\"file\":\"~/other.json\",\"jq\":\".z=1\"}}}"
tc_ok() { jq -r --arg d "$TFD" '.t[$d] // false' "$1" 2>/dev/null; }
# 17. (S6) edit: mode kept, symlink kept, other keys kept, two roles with the same file+filter -> one edit, non-custom roles ignored; second run leaves the file alone
H="$TF/h-c"; mkdir -p "$H/real"; echo '{"keep":1}' > "$H/real/c.json"; chmod 640 "$H/real/c.json"; ln -s real/c.json "$H/cust.json"; echo '{}' > "$H/other.json"
tc_run "$H" "$TR1" "a b c"
R1="$(tc_ok "$H/real/c.json") $(jq -r .keep "$H/real/c.json") $(file_mode_of "$H/real/c.json") $(readlink "$H/cust.json") $(grep -c '^Marked' "$TF/out") $(cat "$TF/rc") $(cat "$H/other.json") $(ls -A "$H" | tr '\n' ' ')$(ls -A "$H/real" | tr '\n' ' ')"
ino="$(ls -i "$H/real/c.json" | cut -d' ' -f1)"; mt="$(stat -c %Y "$H/real/c.json" 2>/dev/null || stat -f %m "$H/real/c.json")"; sleep 1.1; tc_run "$H" "$TR1" "a b c"
mt2="$(stat -c %Y "$H/real/c.json" 2>/dev/null || stat -f %m "$H/real/c.json")"
check "custom trust: edited (mode, link, other keys kept; one edit; claude role ignored) and not rewritten when applied" "$R1 | $([ "$ino" = "$(ls -i "$H/real/c.json" | cut -d' ' -f1)" ] && [ "$mt" = "$mt2" ] && echo same) [$(cat "$TF/out" "$TF/err")]" "true 1 640 real/c.json 1 0 {} cust.json other.json real c.json  | same []"
# 18. (S6) concurrent change: once -> kept via retry; every time -> untouched with a warning; no temp left
H="$TF/h-cc"; mkdir -p "$H"; echo '{"keep":1}' > "$H/cust.json"; chmod 600 "$H/cust.json"
tc_run "$H" "$TR1" "a" "[ -e '$H/seen' ] || { touch '$H/seen'; jq '.x=1' '$H/cust.json' > '$H/w' && cat '$H/w' > '$H/cust.json'; }"
R1="$(tc_ok "$H/cust.json") $(jq -r .x "$H/cust.json") $(jq -r .keep "$H/cust.json") $(cat "$TF/rc")"
H="$TF/h-cd"; mkdir -p "$H"; echo '{"keep":1}' > "$H/cust.json"
tc_run "$H" "$TR1" "a" "n=\$(cat '$H/n' 2>/dev/null || echo 0); echo \$((n+1)) > '$H/n'; jq --argjson n \$n '.x=\$n' '$H/cust.json' > '$H/w' && cat '$H/w' > '$H/cust.json'"
check "custom trust: change during the write kept; constant change -> untouched, warning, clean" "$R1 | $(tc_ok "$H/cust.json") $(jq -r .x "$H/cust.json") $(grep -c '^Warning' "$TF/err") $(cat "$TF/rc") $(find "$H" -name '*orca-roles*' | wc -l | tr -d ' ')" "true 1 1 0 | false 1 1 0 0"
# 19. (S6) failures never abort: missing file, invalid filter, invalid JSON file, incomplete trust field -> warning or silence, file untouched, rc 0, nothing left
H="$TF/h-cf"; mkdir -p "$H"; BAD="{\"a\":{\"agent\":\"custom\",\"command\":\"x\",\"trust\":{\"file\":\"~/cust.json\",\"jq\":\".[\"}}}"
tc_run "$H" "$TR1" "a"; R0="$(ls -A "$H" | wc -l | tr -d ' ') [$(cat "$TF/out" "$TF/err")] $(cat "$TF/rc")"
echo '{"keep":1}' > "$H/cust.json"; cp "$H/cust.json" "$TF/o2"; tc_run "$H" "$BAD" "a"; R1="$(cmp -s "$H/cust.json" "$TF/o2" && echo same) $(grep -c '^Warning' "$TF/err") $(cat "$TF/rc")"
printf '{ nope' > "$H/cust.json"; cp "$H/cust.json" "$TF/o3"; tc_run "$H" "$TR1" "a"; R2="$(cmp -s "$H/cust.json" "$TF/o3" && echo same) $(grep -c '^Warning' "$TF/err") $(cat "$TF/rc")"
tc_run "$H" '{"a":{"agent":"custom","command":"x","trust":{"file":"~/cust.json"}}}' "a"; R3="$(cmp -s "$H/cust.json" "$TF/o3" && echo same) $(grep -c '^Warning' "$TF/err") $(cat "$TF/rc")"
check "custom trust: missing file / invalid filter / invalid JSON / incomplete field never abort and leave no trace" "$R0 | $R1 | $R2 | $R3 | $(find "$H" -name '*orca-roles*' -o -name '*.lock' | wc -l | tr -d ' ') $(grep -c 'trust_custom_roles' "$ROOT/bin/launch.sh")" "0 [] 0 | same 1 0 | same 1 0 | same 1 0 | 0 1"

# 20. (TT2) {scratch}/addDirFlag with a HOME that has a space and a double quote: every path is one shell word
H2="$TMP/h o\"me"; mkdir -p "$H2"; ln -sfn "$KIT" "$H2/.orca-roles"
SDQ="$(cd "$WT2" && KIT="$H2/.orca-roles" scratch_dir cs)"; QQ="$(printf '%q' "$SDQ")"
OUT="$(cd "$WT2" && HOME="$H2" PATH="$FB2:$PATH" ORCA_ROLES_CONFIG="$TMP/cfg2.json" "$H2/.orca-roles/bin/agent.sh" cs 2>&1)"
check "custom: {scratch} and addDirFlag quoted with a space and a quote in HOME" "$OUT" "run $QQ --s --add-dir $QQ --add-dir $(printf '%q' "$H2/a b") --add-dir /c
ENV=$SDQ"
check "custom: the odd scratch path really has a space and a quote and exists" "$(case "$SDQ" in (*' '*'"'*) echo odd;; esac) $([ -d "$SDQ" ] && echo exists)" "odd exists"
# 21. (TT1) the filter must produce exactly one JSON object: anything else leaves the file byte-identical, warns, never says "Marked"
tjq() { jq -Rn --arg f "$1" '$f'; }
tcr() { echo "{\"a\":{\"agent\":\"custom\",\"command\":\"x\",\"trust\":{\"file\":\"~/cust.json\",\"jq\":$(tjq "$1")}}}"; }
H="$TF/h-o"; mkdir -p "$H"; echo '{"keep":1,"trustedWorkspaces":["/z"]}' > "$H/cust.json"
tc_run "$H" "$(tcr '.trustedWorkspaces = ((.trustedWorkspaces // []) + [$dir] | unique)')" a
check "custom trust: a filter returning the whole object edits" "$(jq -c --arg d "$TFD" '(.trustedWorkspaces | index($d) != null), .keep' "$H/cust.json" | tr '\n' ' ') $(grep -c '^Marked' "$TF/out") $(cat "$TF/rc")" "true 1  1 0"
BADF=0; BADL=""
for flt in 'empty' 'select(.x)' '.a, .b' '.missing' '.trustedWorkspaces + [$dir]' '"str"' '1' '[.]' 'true' '(.,.)'; do
  H="$TF/h-o2"; mkdir -p "$H"; rm -f "$H"/cust.json; echo '{"keep":1}' > "$H/cust.json"; cp "$H/cust.json" "$TF/oo"
  tc_run "$H" "$(tcr "$flt")" a
  r="$(cmp -s "$H/cust.json" "$TF/oo" && echo same) $(grep -c '^Warning' "$TF/err") $(grep -c '^Marked' "$TF/out") $(cat "$TF/rc") $(find "$H" -name '*orca-roles*' -o -name '*.lock' | wc -l | tr -d ' ')"
  [ "$r" = "same 1 0 0 0" ] || { BADF=1; BADL="$BADL [$flt => $r]"; }
done
check "custom trust: non-object / multi-value / empty filters rejected, file untouched, warning, no Marked, rc 0" "$BADF$BADL" "0"
# a filter fine on the first read whose second try (after a concurrent change) yields a non-object
H="$TF/h-o3"; mkdir -p "$H"; echo '{"keep":1}' > "$H/cust.json"
tc_run "$H" "$(tcr 'if has("flip") then 1 else .t[$dir] = true end')" a "[ -e '$H/seen' ] || { touch '$H/seen'; jq '.flip=1' '$H/cust.json' > '$H/w' && cat '$H/w' > '$H/cust.json'; }"
check "custom trust: filter that turns non-object on the retry -> untouched (as the other writer left it), warning, no Marked" "$(jq -c . "$H/cust.json") $(grep -c '^Warning' "$TF/err") $(grep -c '^Marked' "$TF/out") $(cat "$TF/rc") $(find "$H" -name '*orca-roles*' | wc -l | tr -d ' ')" '{"keep":1,"flip":1} 1 0 0 0'
}

sec_prompt_paths() {
# Every message and launch points to existing prompt files under prompts/programmer/ (loops over ALL default roles)
pk_setup
check "prompts: 8 files in prompts/programmer/, none flat" "$(find "$PK/prompts/programmer" -maxdepth 1 -name '*.md' | wc -l | tr -d ' '):$(find "$PK/prompts" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" "8:0"
NROLES="$(jq -r '.roles | length' "$PKC")"
[ "$NROLES" -ge 7 ] || { echo "FAIL default config has only $NROLES roles"; FAIL=1; }
# prints "<paths found>:<missing>:<outside programmer/>" for a message
msg_paths() {
  local m="$1" n=0 miss=0 flat=0 p
  while IFS= read -r p; do
    [ -n "$p" ] || continue; n=$((n+1))
    [ -f "$p" ] || miss=$((miss+1))
    case "$p" in "$PK/prompts/programmer/"*) ;; *) flat=$((flat+1));; esac
  done < <(printf '%s' "$m" | grep -oE "$PK/prompts/[^ ,;]*\.md" || true)
  echo "$n:$miss:$flat"
}
printf 'PLANNER=t1\nDEV=t2\n' > "$TMP/pkstate.env"
for r in $(jq -r '.roles | keys_unsorted[]' "$PKC"); do
  [ "$r" = planner ] && continue
  M="$(cd "$TMP" && KIT="$PK" worker_msg "$PKC" "$r")"
  check "worker_msg $r: 2 prompt paths, all exist, all in programmer/" "$(msg_paths "$M")" "2:0:0"
  case "$M" in *"Read $PK/prompts/programmer/common-workers.md and $PK/prompts/programmer/$r.md "*) ;; *) echo "FAIL worker_msg $r: wrong prompt paths: $M"; FAIL=1;; esac
done
M="$(cd "$TMP" && KIT="$PK" planner_msg "$PKC" "planner dev" "$TMP/pkstate.env" "" "" 0)"
case "$(msg_paths "$M")" in [1-9]:0:0) echo "ok   planner_msg: its prompt paths exist, in programmer/";; *) echo "FAIL planner_msg paths: $(msg_paths "$M")"; FAIL=1;; esac
check "planner_msg: names planner.md" "$(printf '%s' "$M" | grep -c "$PK/prompts/programmer/planner.md")" "1"
pk_clean() { (cd "$TMP" && HOME="$PH" ORCA_ROLES_STATE="$TMP/pkstate.env" ORCA_ROLES_CONFIG="$PKC" "$PKL/bin/clean.sh" "$@" 2>&1 | sed "s#$PKL/#$PK/#g"); }
check "clean.sh --msg dev (real): prompt paths exist, in programmer/" "$(msg_paths "$(pk_clean --msg dev)")" "2:0:0"
case "$(msg_paths "$(pk_clean --msg planner)")" in [1-9]:0:0) echo "ok   clean.sh --msg planner (real): prompt paths exist, in programmer/";; *) echo "FAIL clean.sh --msg planner: $(pk_clean --msg planner)"; FAIL=1;; esac
# agent.sh with a stub claude that prints its arguments
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$TMP/pkbin/claude"; chmod +x "$TMP/pkbin/claude"
mkdir -p "$PK/prompts/other" "$PK/prompts-mine" "$TMP/pkext"; : > "$PK/prompts/other/x.md"; : > "$PK/prompts-mine/x.md"; : > "$TMP/pkext/x.md"
cat > "$TMP/pkagent.json" <<J
{ "defaults": { "agent": "claude", "mcp": [], "params": {} }, "mcpServers": {}, "roles": {
    "planner": { "title": "Planner" }, "dev": { "title": "Dev" },
    "sub": { "title": "Sub", "prompt": "$PKL/prompts/other/x.md" },
    "sib": { "title": "Sib", "prompt": "$PKL/prompts-mine/x.md" },
    "ext": { "title": "Ext", "prompt": "$TMP/pkext/x.md" } } }
J
pk_adddirs() { (cd "$TMP" && SDIR="$(KIT="$PKL" scratch_dir "$1")" && HOME="$PH" PATH="$TMP/pkbin:$PATH" ORCA_ROLES_CONFIG="$TMP/pkagent.json" "$PKL/bin/agent.sh" "$1" 2>&1 | grep -A1 -x -e '--add-dir' | grep -v -x -e '--add-dir' -e '--' | grep -v -x -F -- "$SDIR" || true); }
for r in dev planner; do
  check "agent.sh $r: one --add-dir for the kit prompts, none for programmer/" "$(pk_adddirs $r | grep -c -x -- "$PKL/prompts")$(pk_adddirs $r | grep -c programmer)" "10"
done
check "agent.sh prompt in another kit subfolder: no extra --add-dir" "$(pk_adddirs sub | grep -c -x -- "$PKL/prompts")$(pk_adddirs sub | grep -c 'prompts/.')" "10"
check "agent.sh prompt outside the kit: its folder is added" "$(pk_adddirs ext | grep -c -x -- "$TMP/pkext")$(pk_adddirs ext | grep -c -x -- "$PKL/prompts")" "11"
check "agent.sh prompt in a sibling folder of the kit prompts (prompts-mine): its folder is added" "$(pk_adddirs sib | grep -c -x -- "$PKL/prompts-mine")$(pk_adddirs sib | grep -c -x -- "$PKL/prompts")" "11"
}

sec_new_role_repo() {
pk_setup
# new-role.sh --repo on a copy of the repo: the prompt goes to prompts/programmer/ and --remove deletes only it
NR="$TMP/nr-repo"; NRH="$TMP/nr-home"; mkdir -p "$NR" "$NRH"
cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$NR/"
ln -sfn "$PK" "$NRH/.orca-roles"
printf '%s' '{"id":"repo-sec","description":"reviews security","prompt":"# Role: SEC\n\n## Report\nx\n"}' > "$TMP/nr-role.json"
nr_run() { (cd "$TMP" && HOME="$NRH" "$PKL/bin/new-role.sh" "$@" 2>&1); }
try nr_run --from-json "$TMP/nr-role.json" --repo "$NR"; check "new-role --repo: creates the role" "$RC" "0"
check "new-role --repo: prompt in prompts/programmer/, none flat" "$([ -f "$NR/prompts/programmer/repo-sec.md" ] && echo y)$([ -e "$NR/prompts/repo-sec.md" ] && echo flat)" "y"
check "new-role --repo: prompt_of resolves to an existing file" "$(p="$(KIT="$NR" prompt_of "$NR/config.default.json" repo-sec)"; [ "$p" = "$NR/prompts/programmer/repo-sec.md" ] && [ -f "$p" ] && echo y)" "y"
try nr_run --remove repo-sec --repo "$NR"; check "new-role --remove --repo: removes the role" "$RC:$(jq -r '.roles | has("repo-sec")' "$NR/config.default.json")" "0:false"
check "new-role --remove --repo: only its prompt is deleted, the 8 defaults remain" "$([ -e "$NR/prompts/programmer/repo-sec.md" ] && echo left):$(find "$NR/prompts/programmer" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" ":8"
}

sec_install_flat() {
# install.sh over a kit that still has the old flat prompts leaves only prompts/programmer/
IH="$TMP/inst-home"; mkdir -p "$IH/.orca-roles/prompts"
for f in auditor common-workers deployer dev e2e-tester planner researcher tester; do echo old > "$IH/.orca-roles/prompts/$f.md"; done
(cd "$TMP" && HOME="$IH" bash "$ROOT/install.sh" </dev/null >/dev/null 2>&1) || { echo "FAIL install.sh over old flat prompts"; FAIL=1; }
check "install.sh: no flat prompt left, 8 in prompts/programmer/" "$(find "$IH/.orca-roles/prompts" -maxdepth 1 -name '*.md' | wc -l | tr -d ' '):$(find "$IH/.orca-roles/prompts/programmer" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" "0:8"
}

sec_guard() {
# A section that dies on an unbound variable must not end the script with exit 0 (bash 3.2 does)
GR="$TMP/guard-root"; mkdir -p "$GR/tests"; ln -sfn "$ROOT/bin" "$GR/bin"; ln -sfn "$ROOT/prompts" "$GR/prompts"; ln -sfn "$ROOT/config.default.json" "$GR/config.default.json"; ln -sfn "$ROOT/install.sh" "$GR/install.sh"
sed 's/^sec_syntax() {$/&\
echo "$SMOKE_UNBOUND_PROBE"/' "$ROOT/tests/smoke.sh" > "$GR/tests/smoke.sh"
check "guard: the probe is injected into the copy" "$(cmp -s "$ROOT/tests/smoke.sh" "$GR/tests/smoke.sh" && echo same || echo changed)" "changed"
try bash -c 'bash "$0" syntax 2>&1' "$GR/tests/smoke.sh"
check "guard: unbound variable inside a section -> exit non-zero, no ALL OK" "$([ "$RC" != 0 ] && echo nonzero):$(printf '%s\n' "$OUT" | grep -c '^ALL OK')" "nonzero:0"
check "guard: it died on the probe" "$(printf '%s\n' "$OUT" | grep -c 'SMOKE_UNBOUND_PROBE: unbound variable')" "1"
try bash "$ROOT/tests/smoke.sh" syntax
check "guard: the same section unmodified -> exit 0 with ALL OK" "$RC:$(printf '%s\n' "$OUT" | grep -c '^ALL OK')" "0:1"
}

sec_checkpoint() {
# checkpoint.sh: records the tree under refs/orca-roles/checkpoints/ without touching HEAD, index, branch or working tree
CP="$ROOT/bin/checkpoint.sh"; CD="$TMP/cp"; rm -rf "$CD"; mkdir -p "$CD"
cpg() { git -C "$CD" "$@"; }
cpg init -q -b main; cpg config user.email t@example.com; cpg config user.name tester
printf 'ign\n' > "$CD/.gitignore"; printf 'a\n' > "$CD/f"; printf 'b\n' > "$CD/g"; mkdir "$CD/sub"; printf 's\n' > "$CD/sub/h"
cpg add -A; cpg commit -q -m init
cpstate() { ( cd "$CD" && echo "head=$(git rev-parse HEAD) branch=$(git symbolic-ref HEAD) idx=$(shasum < "$(git rev-parse --git-path index)" | cut -d' ' -f1)"; git diff --cached | shasum | cut -d' ' -f1; GIT_OPTIONAL_LOCKS=0 git status --porcelain=v1 -uall | shasum | cut -d' ' -f1; find . -path ./.git -prune -o -type f -print | sort | xargs shasum | shasum | cut -d' ' -f1 ); }
cprun() { CPRC=0; CPOUT="$(cd "${CPDIR:-$CD}" && bash "$CP" "$@" 2>"$TMP/cp.err")" || CPRC=$?; CPERR="$(cat "$TMP/cp.err")"; }
printf 'a2\n' >> "$CD/f"; printf 'staged\n' > "$CD/g"; cpg add g; printf 'n1\n' > "$CD/new1"; printf 'x\n' > "$CD/ignored"; printf 'ignored\n' >> "$CD/.gitignore"
printf 'junk\n' > "$CD/ign"
S0="$(cpstate)"
cprun s1 1; R1="$(printf '%s\n' "$CPOUT" | head -1)"
check "checkpoint: exit 0 and prints the ref" "$CPRC:$(printf '%s' "$R1" | grep -c '^refs/orca-roles/checkpoints/.*/s1-c1$')" "0:1"
check "checkpoint: HEAD, branch, index, staged diff, status and working tree unchanged" "$(cpstate)" "$S0"
check "checkpoint: prints the whole-step diff command and no tracked-only one" "$(printf '%s\n' "$CPOUT" | grep -cF "git diff HEAD $R1"):$(printf '%s\n' "$CPOUT" | grep -c 'git diff')" "1:1"
check "checkpoint: records modified, staged and untracked files" "$(cpg diff --name-only HEAD "$R1" | tr '\n' ' ')" ".gitignore f g new1 "
check "checkpoint: excludes ignored files" "$(cpg ls-tree -r --name-only "$R1" | grep -cE '^(ign|ignored)$' || true)" "0"
check "checkpoint: the commit has HEAD as its parent and the refs live outside the branch" "$(cpg rev-parse "$R1^"):$(cpg for-each-ref --format='%(refname)' refs/heads)" "$(cpg rev-parse HEAD):refs/heads/main"
printf 'a3\n' >> "$CD/f"; printf 'n2\n' > "$CD/sub/new2"; rm "$CD/sub/h"; S1="$(cpstate)"
cprun s1 2; R2="$(printf '%s\n' "$CPOUT" | head -1)"
check "checkpoint: second call exits 0 and leaves everything unchanged" "$CPRC:$([ "$(cpstate)" = "$S1" ] && echo same)" "0:same"
check "checkpoint: diff between two checkpoints is exactly the change made between them" "$(cpg diff --name-status "$R1" "$R2" | tr '\t\n' '::' | tr ':' ' ' | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')" "A D M f sub/h sub/new2 "
check "checkpoint: that diff has no other content" "$(cpg diff "$R1" "$R2" | grep -E '^[+-][^+-]' | LC_ALL=C sort | tr '\n' ' ')" "+a3 +n2 -s "
check "checkpoint: the previous-checkpoint diff command for n=2 is printed, and nothing else" "$(printf '%s\n' "$CPOUT" | grep -cF "Since the previous checkpoint:"):$(printf '%s\n' "$CPOUT" | grep -cF "git diff $R1 $R2"):$(printf '%s\n' "$CPOUT" | grep -c 'git diff')" "1:1:2"
# refusals write nothing
REFS0="$(cpg for-each-ref refs/orca-roles | wc -l | tr -d ' ')"; S2="$(cpstate)"
for bad in '../x 1' 's1 x' 's1 -1' 's1 1.5' 's1 01' 'S1 1' 's/1 1' '-x 1' 's1' '' 's1 1 2' '"" 1'; do
  eval "cprun $bad"
  check "checkpoint: rejects [$bad], nothing written" "$([ "$CPRC" != 0 ] && echo fail):$([ -n "$CPERR" ] && echo msg):$(cpg for-each-ref refs/orca-roles | wc -l | tr -d ' ')" "fail:msg:$REFS0"
done
cprun s1 1; check "checkpoint: an existing ref is refused without --force" "$CPRC:$(printf '%s' "$CPERR" | grep -c 'already exists'):$(cpg rev-parse "$R1")" "1:1:$(cpg rev-parse "$R1")"
OLD="$(cpg rev-parse "$R1")"; cprun --force s1 1
check "checkpoint: --force overwrites it" "$CPRC:$([ "$(cpg rev-parse "$R1")" != "$OLD" ] && echo moved)" "0:moved"
check "checkpoint: state still unchanged after refusals and --force" "$(cpstate)" "$S2"
# from a subdirectory
CPDIR="$CD/sub" cprun s2 1; check "checkpoint: works from a subdirectory and records the whole tree" "$CPRC:$(cpg ls-tree -r --name-only "$(printf '%s\n' "$CPOUT" | head -1)" | grep -c '^new1$')" "0:1"
# list and clear
cprun --list; check "checkpoint: --list shows every checkpoint" "$CPRC:$(printf '%s\n' "$CPOUT" | grep -c '^refs/orca-roles/')" "0:3"
cprun --list s1; check "checkpoint: --list <step> shows only that step" "$CPRC:$(printf '%s\n' "$CPOUT" | grep -c '/s1-c')" "0:2"
cprun --list s; check "checkpoint: --list does not match a step that is only a prefix" "$CPRC:$(printf '%s\n' "$CPOUT" | grep -c '^refs/')" "0:0"
cprun --clear ../x; check "checkpoint: --clear rejects an invalid step" "$([ "$CPRC" != 0 ] && echo fail):$(cpg for-each-ref refs/orca-roles | wc -l | tr -d ' ')" "fail:3"
cprun --clear s1; check "checkpoint: --clear deletes that step's refs only" "$CPRC:$(cpg for-each-ref refs/orca-roles | grep -c '/s1-c'):$(cpg for-each-ref refs/orca-roles | grep -c '/s2-c1')" "0:0:1"
check "checkpoint: --clear leaves HEAD, index, branch and tree unchanged" "$(cpstate)" "$S2"
# refs are per worktree: two worktrees of one repo, same step name
cpg add -A; cpg commit -q -m two; cpg worktree add -q "$TMP/cp-linked" -b other
printf 'l\n' > "$TMP/cp-linked/only-linked"
CPDIR="$TMP/cp-linked" cprun s1 1; RL="$(printf '%s\n' "$CPOUT" | head -1)"
check "checkpoint: the same step and n in another worktree does not clash" "$CPRC:$([ "$RL" != "$R1" ] && echo different)" "0:different"
cprun s1 1; check "checkpoint: the main worktree can still record its own s1-c1" "$CPRC" "0"
check "checkpoint: each worktree records only its own tree" "$(cpg ls-tree -r --name-only "$RL" | grep -c only-linked):$(cpg ls-tree -r --name-only "$R1" | grep -c only-linked || true)" "1:0"
CPDIR="$TMP/cp-linked" cprun --clear s1; check "checkpoint: --clear in a worktree keeps the other's refs" "$CPRC:$(cpg for-each-ref refs/orca-roles | grep -c '/s1-c1')" "0:1"
cpg worktree remove --force "$TMP/cp-linked"
# a repository with no commit yet
CE="$TMP/cp-empty"; rm -rf "$CE"; mkdir "$CE"; git -C "$CE" init -q; printf 'x\n' > "$CE/x"
CPDIR="$CE" cprun e 1; check "checkpoint: works before the first commit" "$CPRC:$(git -C "$CE" ls-tree -r --name-only "$(printf '%s\n' "$CPOUT" | head -1)")" "0:x"
# worktree ids: same folder name under different parents, folder names that are not valid in a ref, steps that contain -c<digits>
PA="$TMP/cpa/proj"; PB="$TMP/cpb"; rm -rf "$TMP/cpa" "$PB"; mkdir -p "$PA" "$PB"; pa() { git -C "$PA" "$@"; }
pa init -q -b main; pa config user.email t@example.com; pa config user.name tester; printf 'a\n' > "$PA/f"; pa add -A; pa commit -q -m init
pa worktree add -q "$PB/proj" -b wt-proj
CPDIR="$PA" cprun s1 1; RA="$(printf '%s\n' "$CPOUT" | head -1)"; RAC="$CPRC"
CPDIR="$PB/proj" cprun s1 1; RB="$(printf '%s\n' "$CPOUT" | head -1)"
check "checkpoint: two worktrees with the same folder name keep separate refs" "$RAC:$CPRC:$([ "$RA" != "$RB" ] && echo different):$(pa for-each-ref refs/orca-roles | wc -l | tr -d ' ')" "0:0:different:2"
i=0; for nm in 'my repo' 'x.lock' '.hidden' 'a..b' '--' 'proyecto ñ'; do
  i=$((i + 1)); pa worktree add -q "$PB/$nm" -b "wt-n$i"; CPDIR="$PB/$nm" cprun s 1
  check "checkpoint: a worktree folder named [$nm] gets a valid id" "$CPRC:$(printf '%s\n' "$CPOUT" | head -1 | grep -cE '^refs/orca-roles/checkpoints/[A-Za-z0-9][A-Za-z0-9-]*-[0-9a-f]{10}/s-c1$')" "0:1"
done
CPDIR="$PA" cprun s1-c1 1; CPDIR="$PA" cprun --list s1
check "checkpoint: --list <step> does not match another step that contains -c<digits>" "$CPRC:$(printf '%s\n' "$CPOUT" | grep -c '^refs/'):$(printf '%s\n' "$CPOUT" | grep -c '/s1-c1 ')" "0:1:1"
CPDIR="$PA" cprun --clear s1; check "checkpoint: --clear <step> keeps the refs of a step named <step>-c<digits>" "$CPRC:$(pa for-each-ref refs/orca-roles | grep -c '/s1-c1-c1$'):$(pa rev-parse -q --verify "$RA" >/dev/null && echo kept || echo gone)" "0:1:gone"
CPDIR="$PA" cprun gap 5; check "checkpoint: no round-diff command when the previous checkpoint does not exist" "$CPRC:$(printf '%s\n' "$CPOUT" | grep -c 'git diff')" "0:1"
CPDIR="$PA" cprun gap 0; check "checkpoint: n=0 is accepted and has no round-diff command" "$CPRC:$(printf '%s\n' "$CPOUT" | grep -c 'git diff')" "0:1"
CPDIR="$PA" cprun gap 999999999; check "checkpoint: the largest n (9 digits) is accepted" "$CPRC" "0"
R9="$(pa for-each-ref refs/orca-roles | wc -l | tr -d ' ')"; CPDIR="$PA" cprun gap 1000000000
check "checkpoint: n with 10 digits is refused and nothing is written" "$([ "$CPRC" != 0 ] && echo fail):$(pa for-each-ref refs/orca-roles | wc -l | tr -d ' ')" "fail:$R9"
for nm in 'my repo' 'x.lock' '.hidden' 'a..b' '--' 'proyecto ñ' proj; do pa worktree remove --force "$PB/$nm"; done
# a merge in progress (unmerged index entries) and an intent-to-add entry
CM="$TMP/cp-merge"; rm -rf "$CM"; mkdir "$CM"; cm() { git -C "$CM" "$@"; }
cm init -q -b main; cm config user.email t@example.com; cm config user.name tester
printf 'base\n' > "$CM/f"; cm add -A; cm commit -q -m base; cm checkout -q -b side; printf 'side\n' > "$CM/f"; cm commit -qam side
cm checkout -q main; printf 'main\n' > "$CM/f"; cm commit -qam main; cm merge side >/dev/null 2>&1 || true
printf 'q\n' > "$CM/q"; cm add -N q
CD_SAVE="$CD"; CD="$CM"; SM="$(cpstate)"; CD="$CD_SAVE"
CPDIR="$CM" cprun mg 1
CD_SAVE="$CD"; CD="$CM"; SM2="$(cpstate)"; CD="$CD_SAVE"
check "checkpoint: a merge in progress and an intent-to-add entry stay untouched" "$CPRC:$(cm ls-files -u | wc -l | tr -d ' '):$([ "$SM" = "$SM2" ] && echo same)" "0:3:same"
check "checkpoint: it records the conflicted file as it is in the working tree and the intent-to-add file" "$(cm show "$(printf '%s\n' "$CPOUT" | head -1):f" | grep -c '^<<<<<<<'):$(cm ls-tree -r --name-only "$(printf '%s\n' "$CPOUT" | head -1)" | grep -c '^q$')" "1:1"
# identity, stale-index warning and --force
CID="$(cpg log -1 --format='%an <%ae>|%cn <%ce>' "$R1")"
check "checkpoint: author and committer are orca-roles even with user.name/email configured" "$CID" "orca-roles <orca-roles@localhost>|orca-roles <orca-roles@localhost>"
cprun s3 1; check "checkpoint: no warning for a normal tree" "$CPRC:$CPERR" "0:"
cpg update-index --assume-unchanged f; cprun s3 2
check "checkpoint: warns about an assume-unchanged file, exit 0, ref written" "$CPRC:$(printf '%s' "$CPERR" | grep -c '^Warning: 1 file(s) marked assume-unchanged or skip-worktree are recorded as in the index, not as in the working tree: f$'):$(cpg rev-parse -q --verify "$(printf '%s\n' "$CPOUT" | head -1)" >/dev/null && echo ref)" "0:1:ref"
cpg update-index --no-assume-unchanged f; cpg update-index --skip-worktree g; cprun s3 3
check "checkpoint: warns about a skip-worktree file" "$CPRC:$(printf '%s' "$CPERR" | grep -c '^Warning: 1 file(s).*: g$')" "0:1"
cpg update-index --no-skip-worktree g; cprun s3 4; check "checkpoint: no warning once the flags are cleared" "$CPRC:$CPERR" "0:"
cprun s3 4; check "checkpoint: an existing ref is refused without --force (again)" "$CPRC:$(printf '%s' "$CPERR" | grep -c 'already exists')" "1:1"
# the prompts
PLP="$ROOT/prompts/programmer/planner.md"; TS="$ROOT/prompts/programmer/tester.md"; AU="$ROOT/prompts/programmer/auditor.md"
pb() { printf '%s' "$1" | grep -qF -- "$3" || { echo "FAIL $2 lost '$3'"; FAIL=1; }; }
LED="$(grep '\*\*Ledger\.\*\*' "$PLP" || true)"
for frag in 'ledger-<step>.md' 'your scratchDir' 'the base commit' 'the checkpoint refs' 'mutants killed or survived, tests added' 'findings open and closed' 'what was not audited' 'Update it after every report' 'source of every brief' 'before proposing the close commit' 'closed or accepted by the user'; do pb "$LED" "planner.md ledger bullet" "$frag"; done
T3="$(grep '^3\. \*\*Tests\*\*' "$PLP" || true)"; A4="$(grep '^4\. \*\*Audit\*\*' "$PLP" || true)"
pb "$T3" "planner.md step 3" 'checkpoint.sh <step> <n>'; pb "$T3" "planner.md step 3" 'after every Dev or Tester `worker_done` in the step'; pb "$T3" "planner.md step 3" '(n = 1 for the first report of the step, +1 for each later report)'; pb "$T3" "planner.md step 3" '); after Dev'"'"'s, create the Tester'"'"'s task with a brief'; pb "$T3" "planner.md step 3" 'with a brief (see "Briefed rounds") instead of a chain of dependent tasks'; grep -qF '<step>-c<n-1>' "$PLP" && { echo "FAIL planner.md still has the consecutive-checkpoint wording <step>-c<n-1>"; FAIL=1; }; pb "$T3" "planner.md step 3" 'brief'
pb "$A4" "planner.md step 4" 'the Auditor does not take part in each step'; pb "$A4" "planner.md step 4" 'Set audit'; pb "$A4" "planner.md step 4" "A step ends with the Tester's"
[ -z "$(printf '%s' "$A4" | grep -F 'create the Auditor' || true)" ] || { echo "FAIL planner.md step 4 still creates a per-step Auditor task"; FAIL=1; }
[ -z "$(printf '%s' "$T3$A4" | grep -F -- '--deps' || true)" ] || { echo "FAIL planner.md steps 3 and 4 still chain tasks with --deps"; FAIL=1; }
NP="$(grep 'Never pre-create Tester or Auditor tasks' "$PLP" || true)"; pb "$NP" "planner.md no-pre-created bullet" '--deps'; pb "$NP" "planner.md no-pre-created bullet" 'generic specs'; pb "$NP" "planner.md no-pre-created bullet" 'after the previous report'
BR="$(grep '\*\*Briefed rounds\.\*\*' "$PLP" || true)"
for frag in 'self-contained brief' 'The task' 'acceptance criteria with their pass/fail examples' 'threat model and rejection threshold' 'The state' 'the files changed' 'what Dev did and decided' 'for the Auditor, also what the Tester did and found' 'what earlier rounds already verified' 'the findings still open' '"not audited" items carried forward' 'carries the whole step'"'"'s diff' 'with ref = the latest checkpoint' 'a later brief to a role carries' 'ref of the checkpoint its previous brief pointed to' '<latest ref>' 'since that role last looked' 'test-only rounds included' '`<step>` is lowercase letters, digits and hyphens' 'passes information only' 'never tells the Tester or the Auditor what to test, mutate or look at, or where the risks are'; do pb "$BR" "planner.md briefed-rounds bullet" "$frag"; done
printf '%s' "$BR" | grep -qiE 'test (the|these|every)|you must mutate|focus on' && { echo "FAIL planner.md briefed-rounds bullet contains a known prescriptive phrase (a denylist of known phrases, not a proof that it never prescribes)"; FAIL=1; }
FX="$(grep '\*\*Fix rounds carry only what changed' "$PLP" || true)"
for frag in "never points to a task id" 'the findings assigned to that worker exactly as the reviewer wrote them' '(text, file:line, reproduction)' 'plus any contract change' 'cleaned since its previous task in this step' "also gets the step's task again" 'Tester rounds and Auditor tasks also follow "Briefed rounds"'; do pb "$FX" "planner.md fix-rounds bullet" "$frag"; done
printf '%s' "$FX" | grep -qF 'references that task' && { echo "FAIL planner.md fix-rounds bullet still points to a task id"; FAIL=1; }
[ "$(grep -c 'Fix rounds carry only what changed' "$PLP")" = 1 ] || { echo "FAIL planner.md: fix-rounds bullet missing or duplicated"; FAIL=1; }
pb "$(grep '^   - \*\*After the commit\*\*' "$PLP" || true)" "planner.md close" 'clear the step'"'"'s checkpoints: `~/.orca-roles/bin/checkpoint.sh --clear <step>`.'
grep -qF "are not cleared after the step's commit" "$PLP" && { echo "FAIL planner.md still keeps step checkpoints after the commit"; FAIL=1; }
SA="$(grep '\*\*Set audit\.\*\*' "$PLP" || true)"
[ "$(grep -c '\*\*Set audit\.\*\*' "$PLP")" = 1 ] || { echo "FAIL planner.md: Set audit bullet missing or duplicated"; FAIL=1; }
for frag in 'audits once per set, not per step' 'before proposing the push or the PR' 'the commit the branch started from' '`git diff <base> HEAD`' 'the ledger state of every step' 'Findings at or above medium' 'reviews only the corrections' 'Findings below medium (low and notes): fixed in a Dev/Tester step without a new audit' 'only after the set audit has no open finding at or above medium' 'Clear the set'"'"'s checkpoints (`~/.orca-roles/bin/checkpoint.sh --clear set`) after the set audit closes.' 'never become new commits on top' '--fixup=' '--autosquash' 'checkpoint.sh set' 'before dispatching any fix task' 'with the tree clean (everything committed), record the audited state with `~/.orca-roles/bin/checkpoint.sh set <n>`' '(n = 1 for the first set audit, +1 for each corrections review)' 'the checkpoint recorded for the audited HEAD' 'the force-push needs its own yes' 'Show the user the resulting commit list and rewrite only on their yes' 'The corrections review diffs the recorded checkpoint against the new HEAD' 'the corrections folded into the step commits' 'GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <base>' 'commit each correction as `git commit --fixup=<the step commit it belongs to>`' '(no interactive editor)'; do pb "$SA" "planner.md Set audit bullet" "$frag"; done
printf '%s' "$SA" | grep -qF 'before rewriting, record' && { echo "FAIL planner.md Set audit bullet still records the checkpoint before rewriting"; FAIL=1; }
pb "$(grep 'Threat model and rejection threshold per step' "$PLP" || true)" "planner.md threat model bullet" "Both go in the Tester's tasks and in the set audit's brief"
AK="$(grep 'Work out which kind of task it is' "$AU" || true)"
for frag in '**set audit**' 'the whole diff of a set of steps' 'apply the full method' '**corrections review**' 'only the diff the brief names' 'the findings those corrections answer' 're-run only the mutants that matter for the corrections' 'do not re-review the rest of the set'; do pb "$AK" "auditor.md task kinds" "$frag"; done
pb "$(grep '^1\. Read the Planner' "$TS" || true)" "tester.md step 1" "The Auditor no longer reviews each step, so your review is the step's only one before its commit; the set audit comes later."
check "defaults: maxMutants 8 and maxSelfMutants 3 in config, auditor.md and tester.md" "$(jq -c '[.roles.auditor.params.maxMutants, .roles.tester.params.maxSelfMutants]' "$ROOT/config.default.json"):$(grep -c '^- `maxMutants`: 8$' "$AU"):$(grep -c '^- `maxSelfMutants`: 3$' "$TS")" '[8,3]:1:1'
mm() { echo "$1" > "$TMP/mm-user.json"; upgrade_config "$ROOT/config.default.json" "$TMP/mm-user.json" | jq -c '[.roles.auditor.params.maxMutants, .roles.tester.params.maxSelfMutants]'; }
check "upgrade_config moves the old defaults 15/5 to 8/3" "$(mm '{"roles":{"auditor":{"params":{"maxMutants":15}},"tester":{"params":{"maxSelfMutants":5}}}}')" "[8,3]"
check "upgrade_config keeps a user's own maxMutants/maxSelfMutants" "$(mm '{"roles":{"auditor":{"params":{"maxMutants":12}},"tester":{"params":{"maxSelfMutants":4}}}}')" "[12,4]"
check "upgrade_config gives 8/3 to a config without the keys" "$(mm '{"roles":{}}')" "[8,3]"
RM="$ROOT/README.md"
pb "$(grep '^4\. ' "$RM" || true)" "README flow step 4" 'does not take part in each step'
pb "$(grep '^8\. The \*\*Planner\*\*' "$RM" || true)" "README flow step 8" "Tester's ACCEPTED"
pb "$(grep '^\*\*Set audit\.\*\*' "$RM" || true)" "README Set audit" 'Dev → Tester'; pb "$(grep '^\*\*Set audit\.\*\*' "$RM" || true)" "README Set audit" 'folded into the step commits they belong to'; pb "$(grep '^\*\*Set audit\.\*\*' "$RM" || true)" "README Set audit" 'once per set'; pb "$(grep '^\*\*Set audit\.\*\*' "$RM" || true)" "README Set audit" 'corrections-only review'; pb "$(grep '^\*\*Set audit\.\*\*' "$RM" || true)" "README Set audit" 'findings below medium (low and notes) are fixed without a new audit'
pb "$(grep -F '| **Auditor** |' "$RM" || true)" "README Auditor row" '`maxMutants` 8'
pb "$(grep -F '| **Auditor** |' "$RM" || true)" "README Auditor row" "Existing installs that still had the old defaults (15 and 5) move to the new ones on update; values you set yourself are kept (except exactly 15 and 5 themselves, which every update moves to the new defaults; to keep them, set them in the project's \`.orca-roles.json\`)."
printf '%s' "$(grep -F 'Reviews the security of Dev' "$ROOT/plugin/skills/team/SKILL.md" || true)" | grep -qF 'after the audit' && { echo "FAIL SKILL example role still says 'after the audit'"; FAIL=1; }
pb "$(grep -F 'Reviews the security of Dev' "$ROOT/plugin/skills/team/SKILL.md" || true)" "SKILL example role" 'Use it in steps that touch authentication or data.'
pb "$(grep '^Steps are atomic' "$RM" || true)" "README steps paragraph" 'once Dev and the Tester are done'
pb "$(grep -F '**Briefed rounds.**' "$RM" || true)" "README briefed rounds" "clears each step's checkpoints at the step's commit and the set's at the end of the set audit"
printf '%s' "$(grep -F '**Briefed rounds.**' "$RM" || true)" | grep -qF 'only after the set audit closes' && { echo "FAIL README briefed rounds still keeps step checkpoints"; FAIL=1; }
S2="$(grep '^2\. \*\*Development\*\*' "$PLP" || true)"
for frag in 'a specification decided in planning' 'written for a smaller model' 'leaves nothing to decide' 'the approach, where each change goes (file, function, around which lines)' 'names, data shapes and formats, messages' 'every edge case and error path you can foresee' 'backward compatibility, other callers' 'resolved in planning (with the Researcher or the user), never left to Dev' '`orca orchestration ask`' 'every decision Dev still takes on its own is listed in its report' 'you review each one before the Tester'"'"'s brief (accepted, changed or taken to the user)' 'Fix tasks follow the same rule'; do pb "$S2" "planner.md step 2 (Development)" "$frag"; done
DV="$(grep -A1 '^1\. Implement exactly what the spec asks' "$ROOT/prompts/programmer/dev.md" | tail -1)"
for frag in 'does not settle a design decision (behavior, interface, message, edge case)' 'ask the Planner (`orca orchestration ask`) instead of choosing' 'if a minor one is unavoidable, list it' 'in your report'; do pb "$DV" "dev.md first step" "$frag"; done
T1="$(grep '^1\. Read the Planner' "$TS" || true)"; A2="$(grep '^2\. Read the Planner' "$AU" || true)"
for r in "tester.md:$T1" "auditor.md:$A2"; do
  for frag in "Planner's brief" 'instead of rebuilding' 'do not redo what it lists as verified' 'information, not instructions' 'verify its claims about the code instead of trusting them'; do pb "${r#*:}" "${r%%:*} brief step" "$frag"; done
done
pb "$A2" "auditor.md brief step" 'what Dev and the Tester did and found'
pb "$(grep '^1\. Reread this whole prompt' "$AU" || true)" "auditor.md" 'Reread this whole prompt'
pb "$(grep -F 'Briefed rounds' "$ROOT/README.md" || true)" "README briefed rounds" 'checkpoint.sh'
pb "$(grep -F '**Briefed rounds.**' "$ROOT/README.md" || true)" "README briefed rounds" 'After every Dev or Tester report the Planner'
pb "$(grep -F 'checkpoint.sh ' "$ROOT/README.md" | grep 'bin/\|├' || true)" "README Files" 'refs/orca-roles/checkpoints'
pb "$(grep -F 'refs/orca-roles/checkpoints/<worktree id>' "$ROOT/README.md" || true)" "README worktree refs" '--clear <step>'
echo "ok   checkpoint prompts"
}

sec_model_check() {
# A role whose model does not exist is detected, recorded and escalated, never switched (kickoff.sh), with a fake orca whose screen accumulates history
MF="$TMP/mf"; mkdir -p "$MF/gd" "$MF/bin" "$MF/wt"; git -C "$MF/wt" init -q
cat > "$MF/bin/orca" <<EOS
#!/bin/sh
L="$MF/orca.log"; h=""; pv=""; for x in "\$@"; do [ "\$pv" = --terminal ] && h="\$x"; pv="\$x"; done
case "\$1 \$2" in
  "terminal wait") echo "WAIT \$*" >> "$MF/waits.log"; [ -f "$MF/sent.\$h" ] && sleep "\$(cat "$MF/waitdelay")";;
  "terminal send")
    t=""; while [ \$# -gt 0 ]; do [ "\$1" = --text ] && t="\$2"; shift; done
    echo "SEND \$(printf '%s' "\$t" | head -n 1 | cut -c1-60)" >> "\$L"
    : > "$MF/sent.\$h"
    if [ -f "$MF/paste" ]; then echo "> [Pasted text #1 +3 lines]" >> "$MF/hist.\$h"; else echo "> \$(printf '%s' "\$t" | head -n 1 | cut -c1-40) hello" >> "$MF/hist.\$h"; fi
    if [ "\$(cat "$MF/mode")" = bad ]; then
      if [ -f "$MF/wrap" ]; then w="\$(cat "$MF/wrap")"; { printf '  ⎿  '; sed "s/ \$w/\\\\
     \$w/" "$MF/errtxt"; } >> "$MF/hist.\$h"; else cat "$MF/errtxt" >> "$MF/hist.\$h"; fi
    else echo ready >> "$MF/hist.\$h"; fi;;
  "terminal read") v=1000000; [ -f "$MF/view" ] && v="\$(cat "$MF/view")"; jq -nc --arg s "\$(tail -n "\$v" "$MF/hist.\$h" 2>/dev/null)" '{text: \$s}';;
  "orchestration send")
    to=""; sub=""; body=""; while [ \$# -gt 0 ]; do case "\$1" in --to) to="\$2";; --subject) sub="\$2";; --body) body="\$2";; esac; shift; done
    echo "ESC \$to|\$sub|\$body" >> "\$L"; [ -f "$MF/failsend" ] && exit 1;;
esac
exit 0
EOS
chmod +x "$MF/bin/orca"
CLERR="There's an issue with the selected model (x). It may not exist or you may not have access to it."
echo 0 > "$MF/waitdelay"; export ORCA_ROLES_KICK_SETTLE=0
mf() {  # <config json> <mode: bad | clean> <new roles>; env: ERRTXT ERRWRAP STALE PASTE VIEW REM FAILSEND PRE
  printf '%s' "$1" > "$MF/cfg.json"; : > "$MF/orca.log"; rm -f "$MF"/sent.* "$MF"/hist.* "$MF/paste" "$MF/wrap" "$MF/view" "$MF/gd/orca-roles.models" "$MF/failsend" "$MF/waits.log"
  printf '%s\n' "${ERRTXT:-$CLERR}" > "$MF/errtxt"; [ -z "${ERRWRAP:-}" ] || echo "$ERRWRAP" > "$MF/wrap"; [ -z "${PASTE:-}" ] || : > "$MF/paste"; [ -z "${VIEW:-}" ] || echo "$VIEW" > "$MF/view"
  [ -z "${STALE:-}" ] || for hh in hp hd ht ha; do echo "${STALETXT:-$CLERR}" > "$MF/hist.$hh"; done
  [ -z "${FAILSEND:-}" ] || : > "$MF/failsend"; [ -z "${PRE:-}" ] || printf '%s' "$PRE" > "$MF/gd/orca-roles.models"; printf 'PLANNER=hp\nDEV=hd\nTESTER=ht\nAUDITOR=ha\n' > "$MF/gd/orca-roles.env"
  echo "$2" > "$MF/mode"
  (cd "$MF/wt" && HOME="$TMP/home" PATH="$MF/bin:$PATH" "$KIT/bin/kickoff.sh" "$MF/wt" "$MF/gd/orca-roles.env" "$MF/cfg.json" "$3" "" "${REM:-}" > "$MF/out.log" 2>&1)
}
mfc() { printf '{ "settings": { "kickoffTimeoutSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false }, "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner", "model": "claude-opus-5-5" }, "dev": { %s } } }' "$1"; }
models() { cat "$MF/gd/orca-roles.models" 2>/dev/null | tr '\n' ' '; }
nomodel() { grep -c '/model' "$MF/orca.log" || true; }
escs() { grep '^ESC ' "$MF/orca.log" || true; }
nesc() { escs | wc -l | tr -d ' '; }
DEVOK='"title": "Dev", "model": "claude-opus-5-5"'
BODY="ESC hp|Dev model unavailable|Dev did not start: its model claude-opus-5-5 is not available (There's an issue with the selected model). config.json is unchanged. To fix it yourself: set roles.dev.model in ~/.orca-roles/config.json, then close its tab with ~/.orca-roles/bin/close-role.sh dev and run roles (without options, so this worktree's saved options are kept)."
# model_error_regex
MR="$MF/mr.json"; echo '{"defaults":{"agent":"claude"},"roles":{"c":{},"x":{"agent":"codex"},"u":{"agent":"custom"},"u2":{"agent":"custom","modelError":"boom {model}!"}}}' > "$MR"
check "model_error_regex: claude" "$(model_error_regex "$MR" c m)" "There's an issue with the selected model|The model [^ ]+ is not available on your|API Error \([^)]+\): [^.]*[Mm]odel [Ii][Dd]"
check "model_error_regex: no model, no detection" "$(model_error_regex "$MR" c "")" ""
check "model_error_regex: codex escapes the model id" "$(model_error_regex "$MR" x 'gpt-5.5')" '(unexpected status|ERROR:)[^E]{0,200}gpt-5\.5[^E]{0,200}(does not exist|not supported|model_not_found)'
check "model_error_regex: custom without modelError" "$(model_error_regex "$MR" u m)" ""
check "model_error_regex: custom with {model} escaped" "$(model_error_regex "$MR" u2 'a.b')" 'boom a\.b!'
# claude: bad model -> FAILED, exact escalation, nothing is switched
mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: bad model recorded as FAILED" "$(models)" "DEV=FAILED:claude-opus-5-5 "
check "model-check: exact escalation" "$(escs)" "$BODY"
check "model-check: no /model is ever sent" "$(nomodel)" "0"
check "model-check: role message sent once" "$(grep -c '^SEND ' "$MF/orca.log")" "1"
mf "$(mfc "$DEVOK")" clean "dev"
check "model-check: good model recorded, no escalation" "$(models):$(nesc)" "DEV=claude-opus-5-5 :0"
for how in new remembered; do
  if [ "$how" = new ]; then STALE=1 mf "$(mfc "$DEVOK")" clean "dev"; else STALE=1 REM=dev mf "$(mfc "$DEVOK")" clean "dev"; fi
  check "model-check: stale error, good model, $how role" "$(models):$(nesc):$(nomodel)" "DEV=claude-opus-5-5 :0:0"
done
STALE=1 mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: a stale error does not hide a new one" "$(models):$(nesc)" "DEV=FAILED:claude-opus-5-5 :1"
PASTE=1 mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: collapsed paste still detected" "$(models)" "DEV=FAILED:claude-opus-5-5 "
ERRTXT="The model us.anthropic.claude-x is not available on your account." mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: Bedrock text detected" "$(models):$(escs | grep -c 'The model us.anthropic.claude-x is not available on your)')" "DEV=FAILED:claude-opus-5-5 :1"
ERRWRAP=model mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: wrapped error detected (indented continuation)" "$(models):$(nesc)" "DEV=FAILED:claude-opus-5-5 :1"
BREG="The model us.anthropic.claude-opus-5-5-20260101-v1:0 is not available on your bedrock deployment."
ERRWRAP="on your" ERRTXT="$BREG" mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: wrapped Bedrock error detected" "$(models):$(nesc)" "DEV=FAILED:claude-opus-5-5 :1"
ERRTXT="API Error (us.anthropic.claude-opus-5-5-v9:0): The provided model identifier is invalid.. Run /model to pick a different model." mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: Bedrock invalid model id detected" "$(models):$(nesc)" "DEV=FAILED:claude-opus-5-5 :1"
ERRTXT="API Error (500): Internal server error" mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: other API errors are not model errors" "$(models):$(nesc)" "DEV=claude-opus-5-5 :0"
STALETXT="The model us.anthropic.old-1 is not available on your account." STALE=1 ERRTXT="The model us.anthropic.new-2 is not available on your account." mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: the escalation quotes the newest error" "$(escs | grep -c 'is not available (The model us.anthropic.new-2 is not available on your)')" "1"
ERRTXT="Warning: model x isn't described by this version's model catalog" mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: catalog warning is fine" "$(models):$(nesc)" "DEV=claude-opus-5-5 :0"
VIEW=2 STALE=1 REM=dev mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: known limit: small pane at the first check" "$(models):$(nesc)" "DEV=claude-opus-5-5 :0"
mf "$(mfc "$DEVOK" | jq -c 'del(.defaults.agent)')" bad "dev"
check "model-check: a role with no agent is treated as claude" "$(models)" "DEV=FAILED:claude-opus-5-5 "
# codex
CXERR='ERROR: unexpected status 404 Not Found: The model `gpt-5.5` does not exist or you do not have access to it.'
ERRTXT="$CXERR" mf "$(mfc '"title": "Dev", "agent": "codex", "model": "gpt-5.5"')" bad "dev"
check "model-check: codex bad model -> FAILED" "$(models):$(nesc)" "DEV=FAILED:gpt-5.5 :1"
ERRTXT="${CXERR//gpt-5.5/gpt-5x5}" mf "$(mfc '"title": "Dev", "agent": "codex", "model": "gpt-5.5"')" bad "dev"
check "model-check: codex model id is not a regex" "$(models):$(nesc)" "DEV=gpt-5.5 :0"
ERRTXT="$CXERR" mf "$(mfc '"title": "Dev", "agent": "codex"')" bad "dev"
check "model-check: codex without model, no detection" "$(models)" ""
# custom
mf "$(mfc '"title": "Dev", "agent": "custom", "command": "x", "model": "my-model", "modelError": "boom {model}"')" bad "dev"
ERRTXT="boom my-model" mf "$(mfc '"title": "Dev", "agent": "custom", "command": "x", "model": "my-model", "modelError": "boom {model}"')" bad "dev"
check "model-check: custom modelError -> FAILED" "$(models)" "DEV=FAILED:my-model "
ERRTXT="boom my-model" mf "$(mfc '"title": "Dev", "agent": "custom", "command": "x", "model": "my-model"')" bad "dev"
check "model-check: custom without modelError, no detection" "$(models)" ""
# no model, planner, failed send
mf "$(mfc '"title": "Dev"')" bad "dev"
check "model-check: no model -> no detection, no line" "$(models)" ""
mf "$(mfc "$DEVOK")" bad "planner"
check "model-check: planner FAILED, no escalation" "$(models):$(nesc)" "PLANNER=FAILED:claude-opus-5-5 :0"
RC=0; FAILSEND=1 mf "$(mfc "$DEVOK")" bad "dev" || RC=$?
check "model-check: failed escalation send is ignored" "$RC:$(models):$(grep -c 'Could not tell the Planner: Dev model unavailable' "$MF/out.log")" "0:DEV=FAILED:claude-opus-5-5 :1"
# parallel
mf "$(mfc "$DEVOK" | jq -c '.roles.tester = {"title": "Tester", "model": "claude-opus-5-5"}')" bad "dev tester"
check "model-check: two roles, both lines" "$(sort "$MF/gd/orca-roles.models" | tr '\n' ' ')" "DEV=FAILED:claude-opus-5-5 TESTER=FAILED:claude-opus-5-5 "
check "model-check: two roles, both escalations" "$(escs | cut -d'|' -f2 | sort | tr '\n' ' ')" "Dev model unavailable Tester model unavailable "
check "model-check: no leftover partial files" "$([ -e "$MF/gd/orca-roles.models.d" ] && echo 1 || echo 0)" "0"
MF3="$(mfc "$DEVOK" | jq -c '.roles.tester = {"title": "Tester", "model": "claude-opus-5-5"} | .roles.auditor = {"title": "Auditor", "model": "claude-opus-5-5"}')"
echo 1 > "$MF/waitdelay"; t0=$SECONDS
mf "$MF3" bad "dev tester auditor"
check "model-check: the checks of three roles run in parallel" "$(( SECONDS - t0 < 3 ))" "1"
echo 2 > "$MF/waitdelay"; t0=$SECONDS
mf "$MF3" clean "dev tester auditor"
check "model-check: three roles are checked in parallel" "$(( SECONDS - t0 < 5 ))" "1"
echo 0 > "$MF/waitdelay"
# kept lines, config untouched, bounded waits
PRE=$'AUDITOR=claude-x\nDEV=FAILED:old\n'
mf "$(mfc "$DEVOK")" clean "dev"; unset PRE
check "model-check: other roles' lines kept, own replaced" "$(models)" "AUDITOR=claude-x DEV=claude-opus-5-5 "
check "model-check: config.json is never touched" "$(printf '%s' "$(mfc "$DEVOK")" | cmp -s - "$MF/cfg.json" && echo same || echo changed)" "same"
mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: every wait is bounded by kickoffTimeoutSeconds" "$(grep -vc -e '--timeout-ms 1000 ' "$MF/waits.log" || true)" "0"
check "model-check: waits happened" "$(( $(wc -l < "$MF/waits.log") > 1 ))" "1"
# more edges: remembered bad role, old and new codex error, long text cut, writes confined to the git dir
REM=dev mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: remembered role with a bad model -> FAILED" "$(models):$(nesc)" "DEV=FAILED:claude-opus-5-5 :1"
CXD='"title": "Dev", "agent": "codex", "model": "gpt-5.5"'
STALE=1 STALETXT="$CXERR" ERRTXT="$CXERR" mf "$(mfc "$CXD")" bad "dev"
check "model-check: codex stale error does not merge with the new one" "$(models):$(nesc)" "DEV=FAILED:gpt-5.5 :1"
STALE=1 STALETXT="$CXERR" mf "$(mfc "$CXD")" clean "dev"
check "model-check: codex stale error, good model" "$(models):$(nesc)" "DEV=gpt-5.5 :0"
PAD="$(printf 'x%.0s' $(seq 1 150))"
ERRTXT="ERROR: unexpected status 404 $PAD gpt-5.5 $PAD does not exist" mf "$(mfc "$CXD")" bad "dev"
check "model-check: matched text in the escalation is cut to 200 characters" "$(escs | sed 's/^[^(]*(//; s/)\. config.json.*$//' | tr -d '\n' | wc -c | tr -d ' ')" "200"
mkdir -p "$TMP/home"; HB="$(cd "$TMP/home" && find . | sort | shasum)"
mf "$(mfc "$DEVOK")" bad "dev tester"
check "model-check: nothing outside the git dir is written" "$(find "$MF/wt" -mindepth 1 -not -path "$MF/wt/.git" -not -path "$MF/wt/.git/*" | wc -l | tr -d ' '):$(ls "$MF/gd" | tr '\n' ' '):$(cd "$TMP/home" && find . | sort | shasum | cmp -s - <(echo "$HB") && echo same || echo changed)" "0:orca-roles.env orca-roles.models :same"
# check_config and docs
cc() { echo "$1" > "$MF/cc.json"; check_config "$MF/cc.json"; }
# defaults.modelError inherited and overridden, old and new Bedrock-style errors counted apart
CUD='"title": "Dev", "agent": "custom", "command": "x", "model": "my-model"'
ERRTXT="dflt my-model" mf "$(mfc "$CUD" | jq -c '.defaults.modelError = "dflt {model}"')" bad "dev"
check "model-check: a custom role inherits defaults.modelError" "$(models):$(nesc)" "DEV=FAILED:my-model :1"
ERRTXT="dflt my-model" mf "$(mfc "$CUD, \"modelError\": \"own {model}\"" | jq -c '.defaults.modelError = "dflt {model}"')" bad "dev"
check "model-check: the role's modelError wins over the default" "$(models):$(nesc)" "DEV=my-model :0"
STALETXT="The model us.anthropic.old-1 is not available on your account." STALE=1 ERRTXT="The model us.anthropic.new-2 is not available on your account." mf "$(mfc "$DEVOK")" bad "dev"
check "model-check: an old and a new Bedrock error are two matches" "$(models):$(nesc)" "DEV=FAILED:claude-opus-5-5 :1"
for bad in '""' '5'; do
  check "check_config: defaults modelError $bad rejected" "$(cc "$(printf '{"defaults":{"modelError":%s},"roles":{}}' "$bad")")" "ERROR: invalid configuration: modelError must be a non-empty string"
done
for bad in '""' '5'; do
  check "check_config: role modelError $bad rejected" "$(cc "$(printf '{"roles":{"dev":{"modelError":%s}}}' "$bad")")" "ERROR: invalid configuration: modelError must be a non-empty string"
done
check "check_config: modelError string accepted" "$(cc '{"roles":{"dev":{"modelError":"x {model}"}}}')" ""
PL="$ROOT/prompts/programmer/planner.md"
for frag in 'model unavailable' 'comes from the kit' 'fix it themselves' 'Never dispatch tasks to a role that did not start' 'close-role.sh'; do
  grep -F 'model unavailable' "$PL" | grep -qF -- "$frag" || { echo "FAIL planner.md: the model unavailable sentence lost '$frag'"; FAIL=1; }
done
grep -qF 'modelError' "$ROOT/README.md" || { echo "FAIL README without modelError"; FAIL=1; }
grep -F 'A role never answers its first message' "$ROOT/README.md" | grep -qF 'model unavailable' || { echo "FAIL README troubleshooting row without the new behaviour"; FAIL=1; }
grep -F 'does not answer its first message' "$ROOT/plugin/skills/team/SKILL.md" | grep -qF 'modelError' || { echo "FAIL SKILL.md row without modelError"; FAIL=1; }
echo "ok   model-check docs"
}

sec_models() {
# models.sh: fake claude, codex and custom commands on PATH (never the real ones), a fake HOME, a private TMPDIR
MM="$TMP/models"; rm -rf "$MM"; mkdir -p "$MM/bin" "$MM/tmp"
cat > "$MM/bin/claude" <<'EOS'
#!/bin/bash
m=""; pv=""; for x in "$@"; do [ "$pv" = --model ] && m="$x"; pv="$x"; done
echo "$FOO" >> "$MM/env.$m"; echo "$*" > "$MM/args.$m"
b="$(cat "$MM/b.$m" 2>/dev/null || echo ok)"
case "$b" in
  ok) echo '{"result":"ok","modelUsage":{"claude-opus-5-5":{"costUSD":0}}}';;
  okplain) echo '{"result":"ok"}';;
  404) echo '{"api_error_status":404,"result":"nope"}'; exit 1;;
  prefix) echo '{"result":"There'"'"'s an issue with the selected model (x). It may not exist."}'; exit 1;;
  prefix2) echo '{"result":"The model x is not available on your account."}'; exit 1;;
  nologin) echo '{"result":"Not logged in · Please run /login"}'; exit 1;;
  text) echo "boom: no network" >&2; exit 1;;
  long) printf 'x%.0s' $(seq 200) >&2; exit 1;;
  okgarbage) echo 'not json at all'; exit 0;;
  tabtext) printf 'a\tb\n' >&2; exit 1;;
  hang) echo $$ > "$MM/hang.pid"; exec sleep 30;;
  slow) sleep 2; echo '{"result":"ok","modelUsage":{"claude-x":{}}}';;
esac
EOS
cat > "$MM/bin/codex" <<'EOS'
#!/bin/bash
if [ "$1 $2" = "debug models" ]; then
  echo "$FOO" > "$MM/codex.env"
  [ -f "$MM/codex.hangdm" ] && exec sleep 30
  [ -f "$MM/codex.dmjson1" ] && { echo "dm: boom" >&2; echo '{"models":[{"slug":"zzz","visibility":"list"}]}'; exit 1; }
  [ -f "$MM/codex.garbage" ] && { echo "not json"; exit 0; }
  [ -f "$MM/codex.fail" ] && { echo "kaboom: no login" >&2; echo "second" >&2; exit 1; }
  echo '{"models":[{"slug":"gpt-b","visibility":"list"},{"slug":"hid","visibility":"hide"},{"slug":"gpt-c","visibility":"list"},{"slug":"gpt-d","visibility":"list"}]}'; exit 0
fi
echo "$*" >> "$MM/codex.argv"; echo "Reading additional input from stdin..." >&2
m=""; pv=""; for x in "$@"; do [ "$pv" = -m ] && m="$x"; pv="$x"; done
TS="2026-10-10T14:12:33.371163Z ERROR codex_api::endpoint::responses_websocket:"
U="unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"
[ -f "$MM/codex.401" ] && { echo "$TS failed to connect" >&2; echo "$TS $U" >&2
  echo '{"type":"thread.started"}'; echo '{"type":"error","message":"'"$U"'"}'; echo '{"type":"turn.failed","error":{"message":"'"$U"', url: https://api.openai.com/v1/responses"}}'; exit 1; }
[ -f "$MM/codex.401err" ] && { echo "$TS failed to connect" >&2; echo "$TS $U" >&2; exit 1; }
[ -f "$MM/codex.layA" ] && { echo "$TS $U" >&2; echo '{"type":"error","message":"EV"}'; echo '{"type":"turn.failed","error":{"message":"TF first"}}'; echo '{"type":"turn.failed","error":{"message":"TF last"}}'; exit 1; }
[ -f "$MM/codex.layB" ] && { echo "$TS $U" >&2; echo 'not json'; echo '{"type":"error","message":"EV first"}'; echo '{"type":"error","message":"EV last"}'; exit 1; }
case "$m" in
  gpt-c) echo '{"type":"error","message":"The model `gpt-c` does not exist or you do not have access to it."}'; exit 1;;
  gpt-d) echo "stream error: connection reset" >&2; exit 1;;
  *) echo '{"type":"turn.completed"}';;
esac
EOS
cat > "$MM/bin/probe" <<'EOS'
#!/bin/bash
printf '%s\n' "$1" >> "$MM/probed"; case "$1" in *bad*) exit 3;; esac
EOS
cat > "$MM/bin/cprobe" <<'EOS'
#!/bin/bash
f="$MM/conc/$$"; mkdir -p "$MM/conc"; : > "$f"; ls "$MM/conc" | wc -l | tr -d ' ' >> "$MM/conc.log"; sleep 0.6; rm -f "$f"
EOS
chmod +x "$MM/bin"/*; export MM
seq 1 10 | sed 's/^/c/' > "$MM/ten.txt"; seq 1 40 | sed 's/^/q/' > "$MM/forty.txt"
printf 'alpha\n  beta  \n\nalpha\n' > "$MM/list.txt"
printf '%s\n' 'id=r1 x' 'junk' 'id=r2' > "$MM/relist.txt"
echo '{"data":[{"id":"j1"},{"id":"j2"}]}' > "$MM/list.json"
printf '%s\n' "it's a \"m\"" 'bad one' > "$MM/odd.txt"
jq -n --arg mm "$MM" '{defaults:{agent:"claude",env:{FOO:"def",MY_KEY:"fromdef"}}, roles:{
  cl:{title:"Claude",model:"sonnet",env:{FOO:"role"}}, cl2:{title:"Plain"}, cl4:{model:"my-model"},
  cx:{agent:"codex",model:"gpt-b"}, cx2:{agent:"codex"},
  lines:{agent:"custom",model:"alpha",models:{list:("cat "+$mm+"/list.txt"),probe:($mm+"/bin/probe {model}")}},
  js:{agent:"custom",models:{list:("cat "+$mm+"/list.json"),parse:"json:.data[].id",probe:($mm+"/bin/probe {model}")}},
  re:{agent:"custom",models:{list:("cat "+$mm+"/relist.txt"),parse:"regex:^id=([a-z0-9]+)"}},
  odd:{agent:"custom",models:{list:("cat "+$mm+"/odd.txt"),probe:($mm+"/bin/probe {model}")}},
  envl:{agent:"custom",env:{MY_KEY:"fromrole"},models:{list:"echo $MY_KEY"}}, envd:{agent:"custom",models:{list:"echo $MY_KEY"}},
  conc:{agent:"custom",models:{list:("cat "+$mm+"/ten.txt"),probe:($mm+"/bin/cprobe")}},
  fast:{agent:"custom",models:{list:("cat "+$mm+"/forty.txt"),probe:"true"}},
  hl:{agent:"custom",model:"m3",models:{list:"exec sleep 30"}},
  pw:{agent:"custom",models:{list:"echo p1",probe:("pwd >> "+$mm+"/pwds")}},
  nolist:{agent:"custom",model:"m1"}, nolist2:{agent:"custom"}, failist:{agent:"custom",model:"m2",models:{list:"echo oops >&2; exit 4"}}}}' > "$MM/cfg.json"
ms() { (cd "$PROJ" && PATH="$MM/bin:$PATH" HOME="$TMP/home" ORCA_ROLES_CONFIG="$MM/cfg.json" TMPDIR="$MM/tmp" "$KIT/bin/models.sh" "$@" 2>"$MM/err"); }
mt() { try ms "$@"; }
tabs() { printf '%s' "$OUT" | tr '\t\n' '|;'; }
HB="$(find "$TMP/home" | sort | shasum)"
# claude: listing
mt cl; check "models: claude lists the role's model first, then the aliases, deduplicated" "$RC:$(tabs)" "0:sonnet;opus;haiku;fable"
check "models: claude's note is on stderr" "$(cat "$MM/err")" "Claude Code cannot list the models of your login; these are its aliases. Use --check to test them."
mt cl4; check "models: claude with another model first" "$(tabs)" "my-model;sonnet;opus;haiku;fable"
mt cl2; check "models: claude without model" "$(tabs)" "sonnet;opus;haiku;fable"
mt Claude; check "models: the role is found by title" "$(tabs)" "sonnet;opus;haiku;fable"
mt -h; check "models: -h prints the header" "$RC:$(printf '%s\n' "$OUT" | head -1 | cut -c1-20)" "0:# Lists the models a"
mt; check "models: no role -> exit 1" "$RC" "1"
mt nosuch; check "models: unknown role -> exit 1 and message" "$RC:$(cat "$MM/err")" "1:Unknown role: nosuch"
check "models: nothing was probed without --check" "$(ls "$MM"/env.* 2>/dev/null | wc -l | tr -d ' ')" "0"
# claude: --check
echo 404 > "$MM/b.opus"; echo prefix > "$MM/b.haiku"; echo prefix2 > "$MM/b.fable"
mt cl --check; check "models: --check classifies ok, 404, and the two result prefixes" "$RC:$(tabs)" "0:sonnet|ok|claude-opus-5-5;opus|unavailable;haiku|unavailable;fable|unavailable"
echo okplain > "$MM/b.sonnet"; echo nologin > "$MM/b.opus"; echo text > "$MM/b.haiku"; echo ok > "$MM/b.fable"
mt cl --check; check "models: ok without modelUsage, not logged in and non-JSON are unknown" "$(tabs)" "sonnet|ok|-;opus|unknown|Not logged in · Please run /login;haiku|unknown|boom: no network;fable|ok|claude-opus-5-5"
check "models: the role's env reaches the probe (role wins over defaults)" "$(tail -1 "$MM/env.sonnet")" "role"
mt cl2 --check; check "models: defaults.env reaches the probe of a role without its own" "$(tail -1 "$MM/env.fable")" "def"
check "models: the probe flags" "$(cat "$MM/args.fable")" '-p --safe-mode --setting-sources local --no-session-persistence --tools  --system-prompt Reply ok. --model fable --output-format json ok'
# timeout and parallelism
for m in sonnet opus haiku fable; do rm -f "$MM/b.$m"; done; echo hang > "$MM/b.haiku"
t0=$SECONDS; ORCA_ROLES_PROBE_TIMEOUT=1 mt cl2 --check
check "models: a hung probe is killed and reported" "$(tabs)" "sonnet|ok|claude-opus-5-5;opus|ok|claude-opus-5-5;haiku|unknown|timed out;fable|ok|claude-opus-5-5"
check "models: the hung probe did not hold the others up" "$(( SECONDS - t0 < 5 ))" "1"
check "models: the hung probe's process is gone after the timeout" "$(kill -0 "$(cat "$MM/hang.pid")" 2>/dev/null && echo alive || echo gone)" "gone"
rm -f "$MM/hang.pid"; echo hang > "$MM/b.haiku"
set -m; (cd "$PROJ" && PATH="$MM/bin:$PATH" HOME="$TMP/home" ORCA_ROLES_CONFIG="$MM/cfg.json" TMPDIR="$MM/tmp" exec "$KIT/bin/models.sh" cl2 --check > /dev/null 2>&1) & MP=$!; set +m
for _ in $(seq 1 50); do [ -s "$MM/hang.pid" ] && break; sleep 0.1; done
HP="$(cat "$MM/hang.pid" 2>/dev/null)"; kill -INT "$MP" 2>/dev/null; wait "$MP" 2>/dev/null || true; sleep 0.3
check "models: SIGINT while a probe hangs kills the probe and removes the temp dir" "$(kill -0 "${HP:-0}" 2>/dev/null && echo alive || echo gone):$([ -n "$HP" ] && echo started):$(ls -A "$MM/tmp" | wc -l | tr -d ' ')" "gone:started:0"
rm -f "$MM/hang.pid"
set -m; (cd "$PROJ" && PATH="$MM/bin:$PATH" HOME="$TMP/home" ORCA_ROLES_CONFIG="$MM/cfg.json" TMPDIR="$MM/tmp" exec "$KIT/bin/models.sh" cl2 --check > /dev/null 2>&1) & MP=$!; set +m
for _ in $(seq 1 50); do [ -s "$MM/hang.pid" ] && break; sleep 0.1; done
HP="$(cat "$MM/hang.pid" 2>/dev/null)"; kill -TERM "$MP" 2>/dev/null; MRC=0; wait "$MP" 2>/dev/null || MRC=$?; sleep 0.3
check "models: SIGTERM while a probe hangs kills the probe, removes the temp dir and exits 130" "$(kill -0 "${HP:-0}" 2>/dev/null && echo alive || echo gone):$([ -n "$HP" ] && echo started):$(ls -A "$MM/tmp" | wc -l | tr -d ' '):$MRC" "gone:started:0:130"
echo slow > "$MM/b.sonnet"; echo slow > "$MM/b.opus"; echo slow > "$MM/b.haiku"
t0=$SECONDS; mt cl2 --check
check "models: three probes of 2 s run in parallel" "$(( SECONDS - t0 < 5 ))" "1"
check "models: the slow probes answered" "$(tabs)" "sonnet|ok|claude-x;opus|ok|claude-x;haiku|ok|claude-x;fable|ok|claude-opus-5-5"
echo long > "$MM/b.sonnet"; mt cl2 --check; check "models: an unknown reason is cut to 80 characters" "$(tabs | cut -d';' -f1 | awk -F'|' '{print $2 ":" length($3)}')" "unknown:80"
for m in sonnet opus haiku; do rm -f "$MM/b.$m"; done
for m in sonnet opus haiku fable; do rm -f "$MM/b.$m"; done
# codex
mt cx; check "models: codex lists its model, then the listed ones" "$RC:$(tabs)" "0:gpt-b;gpt-c;gpt-d"
touch "$MM/codex.fail"; mt cx; check "models: codex debug models failure -> role's model only" "$RC:$(tabs):$(cat "$MM/err")" "0:gpt-b:codex debug models failed: kaboom: no login"
mt cx2; check "models: codex failure without a model -> empty" "$RC:$(tabs)" "0:"
rm -f "$MM/codex.fail"
mt cx --check; check "models: codex --check: ok, unavailable, unknown" "$(tabs)" "gpt-b|ok|-;gpt-c|unavailable;gpt-d|unknown|stream error: connection reset"
# custom
check "models: every codex probe got --ephemeral and --skip-git-repo-check" "$(wc -l < "$MM/codex.argv" | tr -d ' '):$(grep -c -e '--ephemeral' "$MM/codex.argv" | tr -d ' '):$(grep -c -e '--skip-git-repo-check' "$MM/codex.argv" | tr -d ' ')" "3:3:3"
touch "$MM/codex.401"; mt cx --check; check "models: codex 401 reason is the turn.failed message, not the log line" "$(tabs | tr ';' '\n' | cut -d'|' -f3 | cut -c1-34 | sort -u)" "unexpected status 401 Unauthorized"
check "models: codex 401 reason is cut to 80 characters" "$(tabs | tr ';' '\n' | head -1 | cut -d'|' -f3 | wc -c | tr -d ' ')" "81"
rm -f "$MM/codex.401"; touch "$MM/codex.401err"; mt cx --check; check "models: codex 401 with only the timestamped stderr line drops the log prefix" "$(tabs | tr ';' '\n' | cut -d'|' -f3 | cut -c1-17 | sort -u)" "unexpected status"
rm -f "$MM/codex.401err"; touch "$MM/codex.layA"; mt cx --check; check "models: codex reason prefers the last turn.failed message over an error event and the log line" "$(tabs | tr ';' '\n' | cut -d'|' -f3 | sort -u)" "TF last"
rm -f "$MM/codex.layA"; touch "$MM/codex.layB"; mt cx --check; check "models: codex reason falls back to the last error event, skipping non-JSON lines, before the log line" "$(tabs | tr ';' '\n' | cut -d'|' -f3 | sort -u)" "EV last"
rm -f "$MM/codex.layB"; touch "$MM/codex.dmjson1"; mt cx; check "models: codex debug models exiting 1 with valid JSON -> note and the role's model only" "$RC:$(tabs):$(cat "$MM/err")" "0:gpt-b:codex debug models failed: dm: boom"
rm -f "$MM/codex.dmjson1"
rm -f "$MM/codex.401"
touch "$MM/codex.hangdm"; ORCA_ROLES_PROBE_TIMEOUT=2 mt cx; check "models: a hung codex debug models ends with a note and the role's model" "$RC:$(tabs):$(cat "$MM/err")" "0:gpt-b:codex debug models timed out after 2 s"
rm -f "$MM/codex.hangdm"
ORCA_ROLES_PROBE_TIMEOUT=2 mt hl; check "models: a hung models.list ends with a note and the role's model" "$RC:$(tabs):$(cat "$MM/err")" "0:m3:models.list timed out after 2 s"
rm -rf "$MM/conc" "$MM/conc.log"; mt conc --check
check "models: 10 probes all answered" "$(tabs | tr ';' '\n' | grep -c '|ok|-')" "10"
check "models: never more than 6 probes run at once, and they did overlap" "$(sort -n "$MM/conc.log" | tail -1):$(wc -l < "$MM/conc.log" | tr -d ' ')" "6:10"
ORCA_ROLES_PROBE_TIMEOUT=7357 mt fast --check; sleep 0.3
check "models: 40 instant probes answered and left no timer sleep behind" "$(tabs | tr ';' '\n' | grep -c '|ok|-'):$(pgrep -f 'sleep 7357' | wc -l | tr -d ' ')" "40:0"
mt lines; check "models: custom lines parser trims, skips empty lines and deduplicates" "$(tabs)" "alpha;beta"
mt js; check "models: custom json parser" "$(tabs)" "j1;j2"
mt re; check "models: custom regex parser" "$(tabs)" "r1;r2"
mt envl; check "models: the custom list command sees the role's env" "$(tabs)" "fromrole"
mt envd; check "models: the custom list command sees defaults.env when the role has none" "$(tabs)" "fromdef"
mt cx; check "models: codex debug models sees the role's env" "$(cat "$MM/codex.env")" "def"
mt nolist; check "models: custom without list -> role's model, note, exit 0" "$RC:$(tabs):$(cat "$MM/err")" "0:m1:nolist has no models.list in its configuration"
mt nolist2; check "models: custom without list or model -> empty" "$RC:$(tabs):$(cat "$MM/err")" "0::nolist2 has no models.list in its configuration"
mt failist; check "models: a failing list command -> role's model and a note" "$RC:$(tabs):$(cat "$MM/err")" "0:m2:models.list failed: oops"
rm -f "$MM/probed"; mt lines --check; check "models: custom probe ok" "$(tabs)" "alpha|ok|-;beta|ok|-"
check "models: probe got each model" "$(sort "$MM/probed" | tr '\n' ' ')" "alpha beta "
rm -f "$MM/probed"; mt odd --check; check "models: a model with a space and a quote is quoted for the probe" "$(tabs)" "it's a \"m\"|ok|-;bad one|unavailable"
check "models: the probe received each as one argument" "$(sort "$MM/probed" | tr '\n' '/')" "bad one/it's a \"m\"/"
mt re --check; check "models: custom without probe -> unknown" "$(tabs)" "r1|unknown|no models.probe;r2|unknown|no models.probe"
mt PLAIN; check "models: the role is found by title in any letter case" "$RC:$(tabs)" "0:sonnet;opus;haiku;fable"
mt cLaUdE; check "models: the title match ignores case on the other side too" "$RC:$(tabs)" "0:sonnet;opus;haiku;fable"
jq -n '{defaults:{agent:"custom",models:{list:"echo dlist",probe:"echo dprobe"}}, roles:{inh:{}, own:{models:{list:"echo rlist"}}, probeonly:{models:{probe:"true"}}}}' > "$MM/cfg2.json"
ms2() { (cd "$PROJ" && PATH="$MM/bin:$PATH" HOME="$TMP/home" ORCA_ROLES_CONFIG="$MM/cfg2.json" TMPDIR="$MM/tmp" "$KIT/bin/models.sh" "$@" 2>"$MM/err"); }
try ms2 inh; A="$OUT"; try ms2 own; B="$OUT"; try ms2 probeonly; C="$OUT"
check "models: defaults.models is used by a role without its own, the role's key wins, keys merge" "$A:$B:$C" "dlist:rlist:dlist"
rm -f "$MM/pwds"; mt pw --check; mt pw --check  # two runs, one probe each
check "models: probes run in their own folder under the temp dir, not in the caller's" "$(grep -c '/orca-models\.[^/]*/wd\.[0-9]*$' "$MM/pwds"):$(grep -c "^$PROJ\$" "$MM/pwds")" "2:0"
NRC=0; (cd "$PROJ" && PATH="$MM/bin:$PATH" HOME="$TMP/home" env -u ORCA_ROLES_CONFIG TMPDIR="$MM/tmp" "$KIT/bin/models.sh" dev > "$MM/nocfg.out" 2> "$MM/err") || NRC=$?
check "models: without ORCA_ROLES_CONFIG or a saved config it resolves the role from the merged config" "$NRC:$(grep -c . "$MM/nocfg.out" | tr -d ' ' | sed 's/^[1-9][0-9]*$/some/')" "0:some"
echo okgarbage > "$MM/b.sonnet"; echo tabtext > "$MM/b.opus"; mt cl2 --check
check "models: exit 0 with non-JSON output is ok with -, and a tab in a reason becomes a space" "$(tabs | cut -d';' -f1,2)" "sonnet|ok|-;opus|unknown|a b"
for m in sonnet opus; do rm -f "$MM/b.$m"; done
touch "$MM/codex.garbage"; mt cx; check "models: codex debug models exiting 0 with non-JSON -> role's model and a note" "$RC:$(tabs):$(cat "$MM/err" | cut -c1-30)" "0:gpt-b:codex debug models failed: "
rm -f "$MM/codex.garbage"
# nothing written outside the temp dir, which is gone
check "models: nothing written outside the temp dir" "$(find "$TMP/home" | sort | shasum | cmp -s - <(echo "$HB") && echo same || echo changed):$(ls -A "$MM/tmp" | wc -l | tr -d ' ')" "same:0"
# check_config
mcc() { echo "$1" > "$MM/cc.json"; check_config "$MM/cc.json"; }
MERR="ERROR: invalid configuration: models must be {list, parse, probe} (see README)"
for bad in '"x"' '[]' '{"list":false}' '{"probe":5}' '{"probe":false}' '{"probes":"x"}' '{"list":""}' '{"list":5}' '{"probe":""}' '{"probe":[1]}' '{"parse":"xml"}' '{"parse":"json:"}' '{"parse":"regex:"}' '{"parse":""}' '{"parse":5}' 'null'; do
  check "models: check_config rejects role models $bad" "$(mcc "$(jq -nc --argjson m "$bad" '{roles:{dev:{models:$m}}}')")" "$MERR"
done
check "models: check_config rejects defaults models" "$(mcc "$(jq -nc '{defaults:{models:"x"},roles:{}}')")" "$MERR"
for good in '{}' '{"list":"a","parse":"json:.x","probe":"p {model}"}' '{"parse":"lines"}' '{"parse":"regex:(.*)"}' '{"list":"a"}'; do
  check "models: check_config accepts $good" "$(mcc "$(jq -nc --argjson m "$good" '{defaults:{models:$m},roles:{dev:{models:$m}}}')")" ""
done
check "models: planner.md asks for models.sh --check before proposing a model" "$(grep -F 'model unavailable' "$ROOT/prompts/programmer/planner.md" | grep -cF '.orca-roles/bin/models.sh <role> --check')" "1"
unset MM
}

sec_cli() {
# The runner contract (all / some in order / --list / unknown -> exit 2), on a copy whose sections are stubs
CR="$TMP/cli-root"; mkdir -p "$CR/tests"; ln -sfn "$ROOT/bin" "$CR/bin"; ln -sfn "$ROOT/prompts" "$CR/prompts"; ln -sfn "$ROOT/config.default.json" "$CR/config.default.json"
sed -e 's/^SECTIONS=.*/SECTIONS="alpha beta-x gamma"/' -e 's/^\[ \$# -gt 0 \] || set -- \$SECTIONS$/sec_alpha() { echo "marker alpha"; }; sec_beta_x() { echo "marker beta-x"; }; sec_gamma() { echo "marker gamma"; }\
&/' "$ROOT/tests/smoke.sh" > "$CR/tests/smoke.sh"
check "cli: the stub copy differs from the real runner" "$(cmp -s "$ROOT/tests/smoke.sh" "$CR/tests/smoke.sh" && echo same || echo changed)" "changed"
cli_run() { CRC=0; bash "$CR/tests/smoke.sh" "$@" > "$TMP/cli.out" 2> "$TMP/cli.err" || CRC=$?; }
cli_markers() { grep '^marker ' "$TMP/cli.out" | sed 's/^marker //' | tr '\n' ' '; }
cli_run --list; check "cli: --list prints the names, exit 0" "$CRC:$(tr '\n' ' ' < "$TMP/cli.out")" "0:alpha beta-x gamma "
cli_run; check "cli: no arguments runs every listed section, in order" "$CRC:$(cli_markers):$(grep -c '^ALL OK' "$TMP/cli.out")" "0:alpha beta-x gamma :1"
cli_run gamma alpha alpha; check "cli: named sections run only those, in the given order" "$CRC:$(cli_markers)" "0:gamma alpha alpha "
cli_bad() { cli_run "$@"; echo "$CRC:$(wc -l < "$TMP/cli.out" | tr -d ' '):$(wc -l < "$TMP/cli.err" | tr -d ' '):$(grep -c '^  alpha$' "$TMP/cli.err")"; }
check "cli: unknown name alone -> exit 2, empty stdout, list on stderr" "$(cli_bad bogus)" "2:0:4:1"
check "cli: unknown name among valid ones -> exit 2, nothing ran" "$(cli_bad alpha bogus gamma)" "2:0:4:1"
check "cli: valid name first, unknown last -> exit 2, nothing ran" "$(cli_bad gamma bogus)" "2:0:4:1"
check "cli: one argument made of two valid names -> exit 2" "$(cli_bad 'alpha beta-x')" "2:0:4:1"
check "cli: empty argument -> exit 2" "$(cli_bad '')" "2:0:4:1"
check "cli: every listed section has a function, and no function is unlisted" "$(for k in $SECTIONS; do [ "$(type -t "sec_${k//-/_}")" = function ] || echo "$k"; done | wc -l | tr -d ' '):$(compgen -A function sec_ | wc -l | tr -d ' '):$(printf '%s\n' $SECTIONS | wc -l | tr -d ' ')" "0:$(printf '%s\n' $SECTIONS | wc -l | tr -d ' '):$(printf '%s\n' $SECTIONS | wc -l | tr -d ' ')"
}

[ $# -gt 0 ] || set -- $SECTIONS
for s in "$@"; do "sec_${s//-/_}"; done
sleep 1

DONE=1
[ "$FAIL" = 0 ] && echo "ALL OK" || { echo "FAILURES"; exit 1; }
