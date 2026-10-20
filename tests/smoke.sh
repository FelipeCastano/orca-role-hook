#!/usr/bin/env bash
# orca-roles smoke tests: configuration, inheritance, per-project merge, update and the kit's scripts.
# Usage: tests/smoke.sh                  all sections, in order (does not touch ~/.orca-roles)
#        tests/smoke.sh <section>...     only those sections, in the given order
#        tests/smoke.sh --list           the section names, one per line
set -euo pipefail
SECTIONS="syntax prompts rules output-rules config planner-msg flow oracle clean scratch cleanup-msg mcp mcp-placeholders custom-command jira-key composer-title project-config mcp-gitdir empty-lists cli-shim roles-yaml launch-overrides launch status metrics modes academic-research research-defaults new-role-modes planner-skill wizard role-notes plugin-dirs composer-session orca-alias remove-role prompts-misc composer-tab dead-tab agent-flags restart trust-folder forget-trust codex-custom opencode prompt-paths new-role-repo install-flat install-migration install kit-path e2e-browser browser-login e2e-run checkpoint guard model-check models review-skill relaunch scholar cli"
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
KIT="$TMP/kit"; mkdir -p "$KIT"   # not exported: the scripts under test find their kit through the fake HOME, as in real use
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
rm -rf "$PK/prompts/academic-research"   # the mode is available once its planner.md exists: these checks need it unavailable
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
  (cd "$TF/wt" && KIT="$TF/kit" HOME="$1" ORCA_ROLES_TRUST_HOOK="${2:-}" trust_folder >"$TF/out" 2>"$TF/err"; echo $? >"$TF/rc") || true
}
tf_trusted() { jq -r --arg d "$TFD" '.projects[$d].hasTrustDialogAccepted // false' "$1" 2>/dev/null; }
tf_left() { find "$1" -name '.claude.json.orca-roles.*' 2>/dev/null | wc -l | tr -d ' '; }
TFJ='{"oauthAccount":{"email":"a@b"},"projects":{"/other":{"hasTrustDialogAccepted":true}}}'
}

sec_syntax() {
# Syntax and JSON
for f in "$ROOT"/install.sh "$ROOT"/bin/*.sh "$ROOT"/tests/*.sh; do bash -n "$f"; done; echo "ok   bash syntax"
jq empty "$ROOT/config.default.json"; echo "ok   config.default.json is JSON"
check "VERSION equals the version in plugin.json" "$(cat "$ROOT/VERSION")" "$(jq -r .version "$ROOT/plugin/.claude-plugin/plugin.json")"
}

sec_prompts() {
# Every role of the config has a prompt for each of its modes ("all" = every mode named in the config), and each mode has the Planner's and the workers' common prompt
MODES="$(jq -r '[.roles[].modes | select(type == "array") | .[]] | unique | .[]' "$KIT/config.default.json")"
for m in $MODES; do
  for f in planner common-workers; do
    [ -f "$KIT/prompts/$m/$f.md" ] || { echo "FAIL mode $m without prompts/$m/$f.md"; FAIL=1; }
  done
done
for r in $(jq -r '.roles | keys[]' "$KIT/config.default.json"); do
  for m in $(jq -r --arg r "$r" --arg all "$MODES" '.roles[$r].modes // ["programmer"] | if . == "all" then ($all | split("\n") | .[]) else .[] end' "$KIT/config.default.json"); do
    pf="$(jq -r --arg r "$r" --arg m "$m" '.roles[$r].prompt | objects | .[$m] // empty' "$KIT/config.default.json")"   # an explicit prompt path ({kit} = the kit)
    [ -n "$pf" ] || pf="$KIT/prompts/$m/$r.md"
    [ -f "${pf//\{kit\}/$KIT}" ] || { echo "FAIL role $r without a prompt for mode $m"; FAIL=1; }
  done
done; echo "ok   prompts of the default roles"
}

sec_rules() {
# The safety and permission rules the prompts must keep (R<n> = the rule's number). Wording, flow details, formats and README sentences are not pinned.
blk_start
PD="$ROOT/prompts/programmer"; PRD="$ROOT/prompts/pr-reviewer"
# rule <R> <file> <fragment> [<line pattern>]: the file (or, with a pattern, the line it matches) holds the fragment
rule() { local r="$1" f="$2" frag="$3" lp="${4:-}"; if [ -n "$lp" ]; then grep -E -- "$lp" "$f" | grep -qF -- "$frag"; else grep -qF -- "$frag" "$f"; fi || { echo "FAIL rules $r: ${f#$ROOT/} lost '$frag'"; FAIL=1; }; }
prsec() { awk -v t="## $2" '$0 == t {f=1; next} /^## /{f=0} f' "$PRD/$1.md"; }   # prsec <file> <section title>
prrule() { local r="$1" f="$2" sec="$3" pat="$4"; prsec "$f" "$sec" | grep -qE -- "$pat" || { echo "FAIL rules $r: pr-reviewer $f.md, section '$sec', lost '$pat'"; FAIL=1; }; }
# R1 nothing leaves the worktree without the user's explicit yes
rule R1 "$PD/planner.md" "Nothing leaves the worktree without the user's explicit yes"
rule R1 "$PD/planner.md" 'Approving the plan, a step or a commit is not approving a push or a Jira update'
rule R1 "$PD/planner.md" 'Never fixup, autosquash, rebase, amend an earlier commit or force-push' '\*\*Set audit\.\*\*'
rule R1 "$PD/planner.md" 'Push, and open the PR, each only on the user'"'"'s explicit yes' '\*\*Set audit\.\*\*'
# R2 the set is committed at its close in logical commits, only on the user's explicit yes to that list of commits; nothing rewrites history
rule R2 "$PD/planner.md" "only on the user's explicit yes to that list of commits" '^- The set is committed at its close'
rule R2 "$PD/planner.md" 'commit only on a clear yes to that list of commits' '\*\*Set audit\.\*\*'
rule R2 "$PD/planner.md" 'the commits add up exactly to the reviewed tree' '\*\*Set audit\.\*\*'
rule R2 "$PD/planner.md" 'is not approving the commit' '\*\*Set audit\.\*\*'
rule R2 "$PD/planner.md" 'fixed with a normal commit on top, on the user'"'"'s yes' '\*\*Set audit\.\*\*'
rule R2 "$PD/planner.md" 'never a commit per step, per pipeline stage or per fix round' '^- The set is committed at its close'
rule R2 "$PD/planner.md" 'Nothing is committed at step close' '\*\*No commit\.\*\*'
# R3 no AI attribution in commits and PRs, and the check after every commit
for p in common-workers planner; do
  rule R3 "$PD/$p.md" 'git log -1 --format=%B' 'never carry attribution to an AI'
  rule R3 "$PD/$p.md" 'git commit --amend' 'never carry attribution to an AI'
done
rule R3 "$PRD/common-workers.md" 'Nothing you write (reports, findings, files) carries attribution to an AI'
rule R3 "$PRD/common-workers.md" 'no `Co-Authored-By` trailer and no "Generated with' 'carries attribution to an AI'
# R4 no names of people
for p in common-workers planner; do
  rule R4 "$PD/$p.md" 'No names of people anywhere you write'
  rule R4 "$PD/$p.md" 'Handles (`@user`) and email addresses count as names' 'No names of people anywhere you write'
done
rule R4 "$PRD/common-workers.md" 'No names of people anywhere you write'
rule R4 "$PRD/common-workers.md" 'Handles (`@user`) and email addresses count as names' 'No names of people anywhere you write'
rule R4 "$PD/auditor.md" 'Names and stray comments'
grep -rEq '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z.]{2,}' "$ROOT/prompts/" && { echo "FAIL rules R4: a prompt contains an email address"; FAIL=1; }
# R5 worker permissions: no worktrees or terminals, no push, no git state changes, read-only reviewer worktree, no writes to external systems
rule R5 "$PD/common-workers.md" 'Never create worktrees or terminals'
rule R5 "$PD/common-workers.md" 'Never `git push`'
rule R5 "$PD/common-workers.md" 'Never run `git checkout`'
rule R5 "$PD/planner.md" 'Never create worktrees or terminals'
rule R5 "$PD/common-workers.md" 'Never write to Jira, GitHub'
rule R5 "$PD/common-workers.md" 'Do not commit unless the task asks for it'
rule R5 "$PD/common-workers.md" 'Work only inside your worktree'
rule R5 "$PD/deployer.md" 'You never deploy to any environment'
rule R5 "$PD/deployer.md" 'You do not modify production code'
rule R5 "$PD/e2e-tester.md" 'Do not sign in or enter credentials'
rule R5 "$PD/e2e-tester.md" 'You do not modify anything in the project'
rule R5 "$PD/researcher.md" 'Do not modify production code'
# The compact common file for small models keeps the same hard rules (R3, R4, R5, R9, R12, R14, R16) and stays small
PE="$PD/common-peon.md"
rule R3 "$PE" 'git log -1 --format=%B' 'never carry attribution to an AI'
rule R3 "$PE" 'git commit --amend' 'never carry attribution to an AI'
rule R3 "$PE" 'no `Co-Authored-By` trailer' 'never carry attribution to an AI'
rule R3 "$PE" '"Generated with' 'never carry attribution to an AI'
rule R4 "$PE" 'No names of people anywhere you write'
rule R4 "$PE" 'Handles (`@user`) and email addresses count as names' 'No names of people anywhere you write'
rule R5 "$PE" 'Never create worktrees or terminals'
rule R5 "$PE" 'Never `git push`'
rule R5 "$PE" 'Never run `git checkout`'
rule R5 "$PE" 'Never write to Jira, GitHub'
rule R5 "$PE" 'Do not commit unless the task asks for it'
rule R5 "$PE" 'Work only inside your worktree'
rule R5 "$PE" 'Temporary files only in `scratchDir`'
rule R9 "$PE" 'Never wrap commands in `bash -c` or `sh -c`'
rule R9 "$PE" 'Always write in English' '^- Always write'
rule R12 "$PE" 'stop the processes you started'
rule R14 "$PE" 'No heartbeats'
rule R16 "$PE" 'acknowledge each batch once read with `--ack <delivery_id>`'
rule R16 "$PE" 'worker_done' 'ONE'
rule W "$PE" '`reports.md`'
rule P "$PE" 'come in your startup message'
check "rules: common-peon.md is at most 3500 bytes" "$([ "$(wc -c < "$PE" | tr -d ' ')" -le 3500 ] && echo y)" "y"
# R6 install and create only with the user's yes; R7 never approve or merge; R8 credit to lens-review, not copied
# R5 the pr-reviewer worktree is read-only; R11 its Auditor never experiments in the worktree; R14 no heartbeats; R15 convention check
prrule R6 planner "The review skill" 'review-skill\.sh install. only on their explicit yes'
prrule R6 planner "The review skill" 'Do not enable it yourself without their yes'
prrule R6 planner "The team" '"overwrite": true., only on their yes'
prrule R8 planner "Reviewing a PR" 'This review follows lens-review <version> \(https://github\.com/romerox3/lens-review\)\. orca-roles does not include it: it is installed from its repository \(with your yes when the kit installs it\) and reads it now'
prrule R8 planner "Reviewing a PR" 'Review method: lens-review <version> \(https://github\.com/romerox3/lens-review\)\. orca-roles does not include or copy it: it installs it from its repository and runs it; the method and its lenses belong to that project'
prrule R8 planner "Reviewing a PR" 'Whatever you post carries the same "Review method: \.\.\." line'
prrule R8 planner "The review skill" 'does not include or copy it, it installs it from its own repository'
prrule R6 planner "The team" 'On their yes, create each'
prrule R7 planner "Reviewing a PR" 'Never approve, request changes or merge'
prrule R1 planner "Reviewing a PR" 'only with the user.s explicit yes to that exact text'
prrule R5 planner "Limits" 'No commits, no pushes, no code changes in this mode'
prrule R1 planner "Limits" 'Nothing leaves the worktree without the user.s explicit yes'
prrule R15 planner "Limits" 'follows the repository.s own conventions'
prrule R5 common-workers "Limits" 'The worktree is read-only'
prrule R5 common-workers "Limits" 'Never post to GitHub'
prrule R14 common-workers "Communication" 'No heartbeats'
prrule R5 lens-reviewer "Limits" 'The worktree is read-only'
prrule R11 auditor "When you receive a task" 'rsync -a --delete --exclude \.git'
prrule R5 auditor "When you receive a task" 'never experiment in the worktree'
prrule R5 auditor "Limits" 'No mutation testing in this mode'
rule R8 "$ROOT/README.md" 'does not include or copy it' 'https://github.com/romerox3/lens-review'
rule R8 "$ROOT/plugin/skills/team/SKILL.md" 'https://github.com/romerox3/lens-review'
# R9 workers write in English; never wrap commands in bash -c / sh -c
OUTSEC="$(awk '/^## Output$/{f=1;next} /^## /{f=0} f' "$PD/common-workers.md")"
printf '%s' "$OUTSEC" | grep -qF 'Always write in English' || { echo "FAIL rules R9: common-workers.md Output section lost 'Always write in English'"; FAIL=1; }
rule R9 "$PD/common-workers.md" 'Never wrap commands in `bash -c` or `sh -c`'
# R10 workflow: one code task in flight, Dev -> Tester per step, audit once per set, no commit per step (one per set), the Planner writes no production code
rule R10 "$PD/planner.md" 'Only one code task is in flight at any moment' '^- \*\*One step at a time\.\*\*'
rule R10 "$PD/planner.md" 'nobody commits before the set is complete' '\*\*No commit\.\*\*'
rule R10 "$PD/planner.md" "closes only with the Tester's ACCEPTED" '^8\. \*\*Close and report'
rule R10 "$PD/planner.md" 'audits once per set, not per step' '\*\*Set audit\.\*\*'
rule R10 "$PD/planner.md" 'after the previous report' 'Never pre-create Tester or Auditor tasks'
rule R10 "$PD/planner.md" 'You do not write production code'
rule R10 "$PD/dev.md" 'You do not write the test suite'
rule R10 "$PD/tester.md" 'do not write text checks or run text mutants' '^2\. If the change only touches prompt'
rule R10 "$PD/auditor.md" 'do not run text mutants' '^4\. If the change only touches prompt'
rule R10 "$PD/tester.md" 'the rest of this list still applies (including cleanup)' '^2\. If the change only touches prompt'
rule R10 "$PD/auditor.md" 'the rest of the method still applies, including the names-of-people pass' '^4\. If the change only touches prompt'
rule R10 "$PD/planner.md" 'never tells the Tester or the Auditor what to test, mutate or look at' '\*\*Briefed rounds\.\*\*'
# R10 plan audit: a very complex plan goes to the Auditor before the user sees it; otherwise the Planner says it judged it safe
rule R10 "$PD/planner.md" 'decide whether the plan is **very complex**' '^3\. \*\*Before presenting it, audit it\*\*'
rule R10 "$PD/planner.md" 'create an Auditor task, type "plan audit"' '^   If it is very complex'
rule R10 "$PD/planner.md" 'a "plan corrections review"' '^   If it is very complex'
rule R10 "$PD/planner.md" 'you judged it safe to go without the Auditor and why' '^4\. Present the plan'
rule R10 "$PD/auditor.md" 'A **plan audit** has no code yet' '^3\. Work out which kind of task'
rule R10 "$PD/auditor.md" 'It is read-only: no mutants' '^3\. Work out which kind of task'
# R11 where each role works: in place with .orca-bak, one mutant at a time, verified close; experiments in scratchDir; temporaries only there
t=$(awk '/^6\. \*\*Check your own tests with mutation/{f=1;print;next} /^[0-9]+\. /{f=0} /^## /{f=0} f' "$PD/tester.md")
a27="$(grep '^2\. \*\*Baseline' "$PD/auditor.md" || true)$(grep '^7\. \*\*Mutation, in place' "$PD/auditor.md" || true)"
for k in 'in place in the worktree' 'mv <f>.orca-bak <f>' 'One mutant at a time' 'Never use `git checkout`, `git stash` or deleting the backup' 'equal the baseline'; do
  printf '%s' "$t" | grep -qF -- "$k" || { echo "FAIL rules R11: tester.md mutation step lost '$k'"; FAIL=1; }
  printf '%s' "$a27" | grep -qF -- "$k" || { echo "FAIL rules R11: auditor.md mutation passes lost '$k'"; FAIL=1; }
done
printf '%s' "$t$(grep '^7\. \*\*Mutation, in place' "$PD/auditor.md" || true)" | grep -qF '&& mv' && { echo "FAIL rules R11: the restore mv is chained with && in the mutation text"; FAIL=1; }
for p in tester auditor; do
  grep -F 'git checkout' "$PD/$p.md" | grep -vqE 'Never (use|run) .git checkout.' && { echo "FAIL rules R11: $p.md mentions git checkout without forbidding it"; FAIL=1; }
done
rule R11 "$PD/auditor.md" "Never edit Dev's or the Tester's files in any other way" '^- The reviewer verifies, it does not change'
check "rules R11: common-workers.md earlier versions in rev-<full sha>, read-only, copy-rev/" "$(grep -c 'rev-\$sha' "$PD/common-workers.md")$(grep -c 'rev-parse "<commit>^{commit}"' "$PD/common-workers.md")$(grep -c -- '--short' "$PD/common-workers.md" || true)$(grep -c 'copy-rev/' "$PD/common-workers.md")" "1101"
check "rules R11: tester.md mutation in place, no copy" "$(grep -c 'in place in the worktree' "$PD/tester.md")$(grep -c 'rsync' "$PD/tester.md")" "10"
check "rules R11: no prompt tells an agent to delete or use /tmp" "$(grep -rnE '\brm\b|mktemp|/tmp|/var/folders' "$ROOT/prompts/" | wc -l | tr -d ' ')" "0"
# R12 process cleanup
rule R12 "$PD/common-workers.md" 'stop the processes you started'
# Tester and Auditor resource caps
for p in tester auditor; do
  rule caps "$PD/$p.md" 'No GPU'
  rule caps "$PD/$p.md" 'capped at `maxWorkers` parallel processes or threads' '^- \*\*Resources\*\*'
done
prrule caps auditor "Limits" 'Cap every process you run at .maxWorkers. parallel workers'
# R14 no heartbeats
rule R14 "$PD/common-workers.md" 'No heartbeats'
# R16 message batches are acknowledged: the Planner never ends a turn with one open; workers ack what they read and the ack is not a heartbeat
for m in programmer pr-reviewer academic-research; do
  rule R16 "$ROOT/prompts/$m/planner.md" 'Never end a turn holding an unacknowledged delivery' '^  - Never end a turn'
  rule R16 "$ROOT/prompts/$m/planner.md" 'orca orchestration check --ack <delivery_id> --json' '^- \*\*Never block waiting'
  rule R16 "$ROOT/prompts/$m/common-workers.md" 'acknowledges each batch once read, with `--ack <delivery_id>`' '^- A worker that reads its messages'
  rule R16 "$ROOT/prompts/$m/common-workers.md" 'is not a heartbeat' '^- A worker that reads its messages'
  rule R16 "$ROOT/prompts/$m/common-workers.md" 'do not send them' '^- \*\*No heartbeats'
  grep -nE -- '--types' "$ROOT/prompts/$m/planner.md" | grep -vq -- '--wait' && { echo "FAIL rules R16: $m/planner.md uses --types without --wait"; FAIL=1; }
done
# R15 the convention check before proposing a commit, PR or Jira text
rule R15 "$PD/planner.md" 'checked every time' 'follows the repository.s own conventions'
rule R15 "$PD/planner.md" 'Never reuse a format remembered' 'follows the repository.s own conventions'
# academic-research (A<n> = the rule's number)
AD="$ROOT/prompts/academic-research"
# A1 nothing leaves the repository without the user's yes
rule A1 "$AD/planner.md" 'Nothing leaves the repository without the user'"'"'s explicit yes'
rule A1 "$AD/planner.md" 'no HPC job submission' 'Nothing leaves the repository'
rule A1 "$AD/planner.md" 'Never push or touch a remote without the user'"'"'s yes'
rule A1 "$AD/common-workers.md" 'Never post or send anything outside the repository'
rule A1 "$AD/common-workers.md" 'no email' 'Never post or send anything outside the repository'
# A2 the Planner commits, only on the user's yes to that commit; workers never commit
rule A2 "$AD/planner.md" 'workers never commit' 'You make every commit'
rule A2 "$AD/planner.md" 'commit only on a clear yes to that commit' 'You make every commit'
rule A2 "$AD/planner.md" 'approving a stage is not approving the commit' 'You make every commit'
rule A2 "$AD/common-workers.md" 'Nobody commits'
rule A2 "$AD/common-workers.md" 'the Planner commits'
# A3 no fabrication
rule A3 "$AD/planner.md" '**No fabrication.**'
rule A3 "$AD/planner.md" 'No invented data, results, citations, quotes or references' 'No fabrication'
rule A3 "$AD/common-workers.md" '**No fabrication**'
rule A3 "$AD/common-workers.md" 'never invent data, results, citations, quotes or references' 'No fabrication'
# A4 no AI attribution, and the check after every commit
rule A4 "$AD/planner.md" 'never carry attribution to an AI' 'Commit messages, pull requests and Jira'
rule A4 "$AD/planner.md" 'git log -1 --format=%B' 'never carry attribution to an AI'
rule A4 "$AD/planner.md" 'git commit --amend' 'never carry attribution to an AI'
rule A4 "$AD/common-workers.md" 'carries attribution to an AI'
rule A4 "$AD/common-workers.md" 'no `Co-Authored-By` trailer' 'carries attribution to an AI'
# A5 no names of people outside the paper
rule A5 "$AD/planner.md" 'Names of people:' 'never in commit messages, pull requests, Jira'
rule A5 "$AD/planner.md" 'never in commit messages, pull requests, Jira' 'Names of people:'
rule A5 "$AD/planner.md" 'The paper itself is different' 'Names of people:'
rule A5 "$AD/common-workers.md" 'No names of people in your reports'
rule A5 "$AD/common-workers.md" 'may name people' 'No names of people in your reports'
# A6 refs.bib only through scholar.sh bibtex --add (the Writer also needs the user's approval in the task)
rule A6 "$AD/sota.md" 'article/refs.bib changes only through `scholar.sh bibtex --add`'
rule A6 "$AD/sota.md" 'never edit article/refs.bib by hand'
rule A6 "$AD/writer.md" 'article/refs.bib changes only through `scholar.sh bibtex --add`, with the user'"'"'s approval stated in the task'
rule A6 "$AD/writer.md" 'Never edit article/refs.bib by hand'
# A7 PDFs only through scholar.sh pdf; no scraping, no getting past logins or bot challenges
rule A7 "$AD/sota.md" 'never try to get past a login or a bot challenge' 'Never browse or scrape'
rule A7 "$AD/sota.md" 'never download a PDF in any way other than `scholar.sh pdf`' 'Never browse or scrape'
rule A7 "$AD/planner.md" 'never scrape publisher sites or try to get past logins or bot challenges'
# A8 HPC job submission only with the user's approval of that job stated in the task
rule A8 "$AD/planner.md" 'Never submit without that yes' '^4\. \*\*Experiments'
rule A8 "$AD/planner.md" 'states that the user approved that specific submission' '^4\. \*\*Experiments'
rule A8 "$AD/researcher.md" 'only when the task states that the user approved that specific submission'
rule A8 "$AD/researcher.md" 'do not connect to the cluster' 'HPC: prepare the job'
rule A8 "$AD/common-workers.md" 'HPC job submission only when the task states that the user approved that specific submission' '^- HPC job submission'
rule A8 "$AD/common-workers.md" 'only the Researcher submits' '^- HPC job submission'
rule A8 "$AD/common-workers.md" '(no push, no submission, no upload, no email)' '^- Never post or send'
rule A8 "$AD/common-workers.md" 'report it in your `worker_done` and let the Planner ask' '^- Never post or send'
# A9 the five review roles are read-only
rule A9 "$AD/common-workers.md" 'the review roles (Methodology, Tech-Verifier, Evidence, Rigor, Style) write nothing in the repository'
for p in methodology tech-verifier evidence rigor style; do
  rule A9 "$AD/$p.md" 'You write nothing in the repository' '^You '
  rule A9 "$AD/$p.md" 'Read-only (see the common rules)' '^- Read-only'
done
# A10 each worker writes only in its folders
rule A10 "$AD/common-workers.md" '**Write only where your role says.**'
rule A10 "$AD/sota.md" 'Write only in article/literature/ and article/refs.bib'
rule A10 "$AD/researcher.md" 'Write only in experimentation/ and in the generated article/tables/ and article/images/'
rule A10 "$AD/researcher.md" 'Never write the paper'"'"'s text' '^- Write only in experimentation/'
rule A10 "$AD/writer.md" 'You write only in article/' '^- You write only'
rule A10 "$AD/writer.md" 'Never write in article/literature/ (except as the Add a citation task says), article/tables/, article/images/' '^- Never write in'
rule A10 "$AD/common-workers.md" 'otherwise changes the git state (no `git add`, `restore` or `clean` either)' '^- \*\*Write only'
rule A10 "$AD/common-workers.md" 'handles (`@user`) and email addresses count as names' '^- No names'
rule A10 "$AD/researcher.md" 'you change only experimentation/scripts/ and regenerate article/tables/ and article/images/' '^- In the writing phase'
rule A10 "$AD/researcher.md" 'Never change experimentation/results/, the configs or the code in experimentation/src/' '^Resolve the findings'
rule A10 "$AD/researcher.md" 'never run experiments in the writing phase' '^Resolve the findings'
rule A10 "$AD/writer.md" 'Then run `scholar.sh pdf <id>`' 'Only when the task states that the user approved it'
rule A7 "$AD/common-workers.md" 'Never browse or scrape publisher sites and never try to get past a login or a bot challenge' '^- Never browse'
rule A7 "$AD/common-workers.md" 'papers are read only through `scholar.sh`' '^- Never browse'
rule A7 "$AD/common-workers.md" 'Technical documentation (libraries, tools, datasets'"'"' own pages and docs) may be read' '^- Never browse'
rule A7 "$AD/writer.md" 'Exit 2 means no open-access PDF was found' 'Only when the task states that the user approved it'
rule A7 "$AD/evidence.md" '`scholar.sh` is `~/.orca-roles/bin/scholar.sh`'
rule A10 "$AD/planner.md" 'those on tables or figures (Evidence'"'"'s and Rigor'"'"'s) go to a Researcher fix task (scripts and regeneration only), the rest to the Writer' '^2\. \*\*Each section'
rule A10 "$AD/planner.md" 'a finding that needs a new or repeated run means going back to experiment' '^2\. \*\*Each section'
rule A11 "$AD/planner.md" 'a table or figure finding that needs a new or repeated run' '^- Going back from writing'
rule A10 "$AD/sota.md" '`--from` and `--to` take YYYY-MM-DD' '^1\. For each query'
rule A10 "$AD/planner.md" 'years go in the brief as `--from <year>-01-01 --to <year>-12-31`' '^2\. \*\*State of the art'
rule A10 "$AD/writer.md" 'article/literature/manifest.tsv (which papers have a PDF)' '^1\. Read experimentation/PLAN.md'
# A11 phase switch only with the user's yes; back to experiment needs STATE.md committed
rule A11 "$AD/planner.md" "Only with the user's yes." '^- Only with'
rule A11 "$AD/planner.md" 'only with the user'"'"'s yes' '^- Going back from writing'
rule A11 "$AD/planner.md" 'STATE.md at the repository root' '^- Going back from writing'
rule A11 "$AD/planner.md" 'you commit it with the user'"'"'s yes; then `phase.sh experiment`' '^- Going back from writing'
# A12 the Writer cites only existing keys and never invents one
rule A12 "$AD/writer.md" 'only keys that exist in article/refs.bib' '^2\. Cite only'
rule A12 "$AD/writer.md" '[CITATION NEEDED:' '^5\. Where a claim needs'
rule A12 "$AD/writer.md" 'never invent a key' '^5\. Where a claim needs'
# pins of rules the prompts already state: pr-reviewer and academic-research limits, the programmer Planner's relaunch and escalation rules, the Report line of the skeleton
# R2 an ambiguous answer is not a yes to the commits
rule R2 "$PD/planner.md" 'neither is an ambiguous answer ("ok, continue"): ask again' '\*\*Set audit\.\*\*'
# pr-reviewer: no worktrees or terminals, no git state changes, context cleaned only with the user's yes, no AI attribution, kit changes only with the user's yes
prrule R5 planner "Limits" 'Never create worktrees or terminals'
prrule R5 planner "Limits" 'nobody checks out, resets or otherwise changes its git state without the user.s explicit yes'
prrule R1 planner "Limits" 'Never clean a worker.s context without the user.s confirmation'
prrule R3 planner "Limits" 'never carry attribution to an AI'
prrule R6 planner "Limits" 'Never change the kit.s configuration or prompts without the user.s confirmation'
prrule R5 common-workers "Limits" 'Never create worktrees or terminals'
prrule R9 common-workers "Limits" 'Never wrap commands in .bash -c. or .sh -c.'
prrule R5 lens-reviewer "Limits" 'Do not run the project.s code, tests or build unless the brief says so'
prrule R5 auditor "Limits" 'every file you write goes in your scratchDir'
# academic-research: the same limits, closing and cleaning only with the user's yes, kit files only after a yes, the earlier-version folder, the convention check
rule R5 "$AD/common-workers.md" 'Never create worktrees or terminals' '^- Never create worktrees'
rule R9 "$AD/common-workers.md" 'Never wrap commands in `bash -c` or `sh -c`' '^- Never wrap commands'
rule R11 "$AD/common-workers.md" 'rev-$sha' '^- If you need an earlier version of the code'
rule R11 "$AD/common-workers.md" 'it is read-only: do not modify it' '^- If you need an earlier version of the code'
rule R5 "$AD/planner.md" 'Never create worktrees or terminals' '^- Never create worktrees'
rule R5 "$AD/planner.md" "Never close the roles' tabs" '^- After each'
rule R6 "$AD/planner.md" "Never change the kit's configuration or prompts without the user's confirmation" '^- Never change the kit'
rule R1 "$AD/planner.md" "Never clean a worker's context without the user's confirmation" '^- Never clean a worker'
rule R6 "$AD/planner.md" 'Before writing any kit file or opening tabs, explain what you will change and what it affects, and wait for a yes' '^- Before writing any kit file'
rule R15 "$AD/planner.md" 'checked every time before you propose it' '^- Everything you draft for outside the repository'
rule R15 "$AD/planner.md" 'git log -15' '^- Everything you draft for outside the repository'
rule R15 "$AD/planner.md" 'A subject-only commit is not acceptable unless the history does it' '^- Everything you draft for outside the repository'
rule A8 "$AD/tech-verifier.md" 'Never submit HPC jobs' '^- Never submit'
rule A10 "$AD/researcher.md" 'Never change a result by hand and never drop runs that do not fit' '^- Never change a result'
# programmer Planner: relaunch-role.sh only with the user's confirmation, nothing edited in the kit without their yes, no task to a role that did not start
rule R6 "$PD/planner.md" 'the only way to relaunch one with another model is `~/.orca-roles/bin/relaunch-role.sh`, all with the user'"'"'s confirmation' '^- Never create worktrees'
rule R6 "$PD/planner.md" '(edit nothing in `~/.orca-roles` without it; do not use `roles --set` for this)' 'model unavailable'
rule R6 "$PD/planner.md" 'Never dispatch tasks to a role that did not start' 'model unavailable'
# R5 E2E browser: the install only after the user's yes and never by the Planner, never with sudo; the E2E-Tester installs and logs in nothing; only the user saves sessions
rule R5 "$PD/planner.md" 'You never run the install yourself' '^ +- Run `~/.orca-roles/bin/e2e-browser.sh check`'
rule R5 "$PD/planner.md" 'do not ask the user for credentials' '^ +- Once the Deployer has started'
rule R5 "$PD/planner.md" 'Never ask the E2E-Tester to log in or to save a session' '^ +- Once the Deployer has started'
rule R5 "$PD/deployer.md" 'Only when the Planner'"'"'s task says the user approved it' '^Only when'
rule R5 "$PD/deployer.md" 'Never use `sudo`' '^1\. Run `~/.orca-roles/bin/e2e-browser.sh install`'
rule R5 "$PD/deployer.md" 'do not run it: report it for the user' '^2\. Report its output'
rule R5 "$PD/e2e-tester.md" 'do not try to install anything or to authenticate' '^- If a browser tool fails'
rule R5 "$PD/e2e-tester.md" '(and do not install anything)' '^- Do not sign in'
# R5 E2E flows: the E2E-Tester writes only in the flows and evidence folders, never commits or installs there, and writes to shared services only with the user's typed authorization; the Planner asks for it and checks nothing of those folders is staged
rule R5 "$PD/e2e-tester.md" 'never commit or stage them, and never `npm install` inside `<e2eDir>`' '^- You do not modify anything in the project'
rule R5 "$PD/e2e-tester.md" "only after the user's authorization for that scope is in your conversation" '^4\. Writes to a shared service'
rule R5 "$PD/e2e-tester.md" 'otherwise stop and ask' '^4\. Writes to a shared service'
rule R5 "$PD/planner.md" "ask the user, when approving the plan, to type the authorization in the E2E-Tester's tab" '^   c\. Review that plan'
rule R5 "$PD/planner.md" 'before you dispatch the execution' '^   c\. Review that plan'
rule R5 "$PD/planner.md" 'confirm that nothing under `<e2eDir>/` or `<evidenceDir>/` is staged or part of any commit' '\*\*Set audit\.\*\*'
# W written reports (every mode, workers and Planner; W6 the report language is stated by the Planner and used by the worker, W7 the academic-research paper is out of scope): outline approved by the user before writing and relayed by the Planner, descriptive titles, no names of people, scope excludes worker_done, commits, PRs and Jira
for m in programmer pr-reviewer academic-research; do
  for p in reports planner; do
    wf="$ROOT/prompts/$m/$p.md"
    if [ "$p" = reports ]; then ws="$(awk '$0 == "# Written reports" {f=1; next} /^#+ /{f=0} f' "$wf")"   # the workers' rules live in their own file
    else ws="$(awk '$0 == "## Written reports" {f=1; next} /^## /{f=0} f' "$wf")"; fi
    wrule() { printf '%s' "$ws" | grep -qE -- "$2" || { echo "FAIL rules W$1: $m/$p.md Written reports lost '$2'"; FAIL=1; }; }
    [ -n "$ws" ] || { echo "FAIL rules W: $m/$p.md has no Written reports section"; FAIL=1; }
    wrule 1 '^These rules apply to every report the user asks for, in any format'
    wrule 1 'do not apply to worker_done messages, commit messages, pull requests or Jira'
    wrule 2 '^1\. \*\*Titles\.\*\*.*No value claims.*questions or hooks'
    wrule 2 'A section is not titled with its conclusion'
    wrule 3 '^3\. \*\*Sections\.\*\* Before writing, propose the outline .*wait for the user.s approval; a worker sends it to the Planner with `ask`, and the Planner asks the user'
    wrule 4 '^10\. \*\*No names of people\*\*: refer to roles'
    wrule 5 '^11\. \*\*Before delivering\*\*, check the report against rules 1-10'
    if [ "$p" = reports ]; then
      wrule 6 '^9\. \*\*Language\.\*\*.*A worker uses the language the task states; if the task states none, ask the Planner with `ask` before writing'
    else
      wrule 6 'When you hand a report to a worker, state in the task the report.s language .* and its audience'
    fi
    if [ "$m" = academic-research ]; then
      wrule 7 'nor to the paper and its companion files \(the article, supplementary material, cover letter, rebuttal letter\), which follow writer\.md and the paper rules'
    fi
  done
  # The workers' common prompt only points to reports.md (read on demand, so every worker starts lighter); none of the rules is copied back into it
  cw="$ROOT/prompts/$m/common-workers.md"
  [ "$(grep -c '^1\. \*\*Titles\.\*\*' "$ROOT/prompts/$m/reports.md")" = 1 ] || { echo "FAIL rules W: $m/reports.md lost rule 1"; FAIL=1; }
  [ "$(grep -cE '^[0-9]+\. \*\*' "$ROOT/prompts/$m/reports.md")" = 11 ] || { echo "FAIL rules W: $m/reports.md must hold exactly 11 numbered rules"; FAIL=1; }
  [ "$(head -1 "$ROOT/prompts/$m/reports.md")" = "# Written reports" ] || { echo "FAIL rules W: $m/reports.md must start with '# Written reports'"; FAIL=1; }
  [ "$(grep -c '^## Written reports$' "$cw")" = 1 ] || { echo "FAIL rules W: $m/common-workers.md must hold one Written reports heading"; FAIL=1; }
  awk '$0 == "## Written reports" {f=1; next} /^## /{f=0} f' "$cw" | grep -qF '`reports.md`' || { echo "FAIL rules W: $m/common-workers.md Written reports must name reports.md"; FAIL=1; }
  ! grep -qE '^1\. \*\*Titles\.\*\*|^11\. \*\*Before delivering\*\*|^These rules apply to every report the user asks for' "$cw" || { echo "FAIL rules W: $m/common-workers.md still carries the report rules"; FAIL=1; }
  grep -F "a worker's outline (rule 3) reaches you with \`ask\`: show it to the user, and reply with their answer or their changes" "$ROOT/prompts/$m/planner.md" | grep -q '^When the user asks you' || { echo "FAIL rules W3: $m/planner.md lost the outline relay sentence"; FAIL=1; }
  [ "$(grep -c '^## Written reports$' "$ROOT/prompts/$m/planner.md")" = 1 ] || { echo "FAIL rules W: $m/planner.md must hold one Written reports section"; FAIL=1; }
done
blk_end "rules: the safety and permission rules are in the prompts"
}

# The role anchor
sec_output_rules() {
# Anchor: workers get the English rule, the Planner does not
. "$ROOT/bin/lib.sh"
printf '%s' "$(role_anchor "$KIT/config.default.json" dev)" | grep -qF 'Always write in English' || { echo "FAIL role_anchor: workers lack the English rule"; FAIL=1; }
printf '%s' "$(role_anchor "$KIT/config.default.json" planner)" | grep -qF 'Always write in English' && { echo "FAIL role_anchor: the Planner got the English rule"; FAIL=1; }
echo "ok   output rules: role anchor (workers get the English rule, the Planner does not)"
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
check "upgrade: new roles at the end" "$(echo "$U" | jq -r '.roles | keys_unsorted | last')" "$(jq -r '.roles | keys_unsorted | last' "$KIT/config.default.json")"
check "upgrade: user's value kept" "$(echo "$U" | jq -r '.roles.dev.model')" "m-dev"
check "upgrade: user's enabled kept" "$(echo "$U" | jq -r '.roles.tester.enabled')" "false"
check "upgrade: new setting added" "$(echo "$U" | jq -r '.settings.kickoffTimeoutSeconds')" "180"
check "upgrade: mcpServers merged" "$(echo "$U" | jq -r '.mcpServers | keys | join(" ")')" "atlassian context7 ctx playwright"
# The playwright MCP entry: only the exact previous default moves to the pinned stack
D="$ROOT/config.default.json"
pwu() { echo "{\"roles\":{},\"mcpServers\":{\"playwright\":$1}}" > "$TMP/pw-user.json"; upgrade_config "$D" "$TMP/pw-user.json" | jq -c '.mcpServers.playwright'; }
OLDPW='{"command":"npx","args":["-y","@playwright/mcp@latest","--headless","--isolated","--storage-state","{browserState}","--output-dir","{worktree}/{evidenceDir}"]}'
check "upgrade_config: the exact previous playwright default moves to the new default entry" "$(pwu "$OLDPW")" "$(jq -c '.mcpServers.playwright' "$D")"
check "upgrade_config: the old default with a flag added or removed is kept" "$(pwu "$(echo "$OLDPW" | jq -c '.args += ["--viewport-size=1x1"]')" | jq -c '.args | length'):$(pwu "$(echo "$OLDPW" | jq -c '.args |= map(select(. != "--isolated"))')" | jq -r '.command + (.args | length | tostring)')" "9:npx7"
check "upgrade_config: a custom playwright entry keeps its command and args, and one differing only in order or extra key is not migrated" "$(pwu '{"command":"mine","args":["a"]}' | jq -c '[.command, .args]'):$(pwu "$(echo "$OLDPW" | jq -c '.args = (.args[2:] + .args[0:2])')" | jq -r .command):$(pwu "$(echo "$OLDPW" | jq -c '.env = {"X":"1"}')" | jq -r .command)" '["mine",["a"]]:npx:npx'
check "upgrade_config: an unrelated user config gets the default playwright entry" "$(echo '{"roles":{}}' > "$TMP/pw-none.json"; upgrade_config "$D" "$TMP/pw-none.json" | jq -c '.mcpServers.playwright')" "$(jq -c '.mcpServers.playwright' "$D")"
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
jq '.settings.language = "Spanish"' "$KIT/config.json" > "$TMP/lang.json"
case "$(planner_msg "$TMP/lang.json" "planner dev" "$TMP/state.env" "" "" 0)" in *"Always reply to the user in Spanish, whatever language they write in."*) echo "ok   planner_msg: settings.language";; *) echo "FAIL planner_msg language"; FAIL=1;; esac
check "default config: language auto" "$(jq -r '.settings.language' "$ROOT/config.default.json")" "auto"
}

sec_flow() {
# settings.flow: roundCap and workerReportBody; unset or "full" leaves planner_msg and worker_msg byte-identical
clean_fixture
printf 'PLANNER=t1\nDEV=t2\n' > "$TMP/state.env"
PM() { planner_msg "$1" "planner dev" "$TMP/state.env" "" "" 0; }
WM() { (cd "$TMP" && worker_msg "$1" dev); }
BASEP="$(PM "$C" 2>&1)"; BASEW="$(WM "$C" 2>&1)"
jq '.settings.flow = {}' "$C" > "$TMP/f0.json"
check "flow {}: planner_msg unchanged" "$(PM "$TMP/f0.json" 2>&1)" "$BASEP"
check "flow {}: worker_msg unchanged" "$(WM "$TMP/f0.json" 2>&1)" "$BASEW"
jq '.settings.flow = {roundCap: 5}' "$C" > "$TMP/f1.json"
case "$(PM "$TMP/f1.json" 2>&1)" in *"Flow override: stop and check with the user when a step piles up 5 rejected rounds (this replaces the 3 in your prompt)."*) echo "ok   flow roundCap 5: planner sentence";; *) echo "FAIL flow roundCap 5"; FAIL=1;; esac
check "flow roundCap 5: worker_msg unchanged" "$(WM "$TMP/f1.json" 2>&1)" "$BASEW"
jq '.settings.mode = "pr-reviewer"' "$C" > "$TMP/fpr.json"; jq '.settings.flow = {roundCap: 5} | .settings.mode = "pr-reviewer"' "$C" > "$TMP/fpr5.json"
check "flow roundCap 5 in pr-reviewer (no rounds in its flow): planner_msg unchanged" "$(PM "$TMP/fpr5.json" 2>&1)" "$(PM "$TMP/fpr.json" 2>&1)"
for v in 0 -1 '"x"' 2.5 true; do
  jq --argjson v "$v" '.settings.flow = {roundCap: $v}' "$C" > "$TMP/f2.json"
  check "flow roundCap $v: message unchanged" "$(PM "$TMP/f2.json" 2>/dev/null)" "$BASEP"
  case "$(PM "$TMP/f2.json" 2>&1 >/dev/null)" in *"settings.flow.roundCap must be a positive integer"*) echo "ok   flow roundCap $v: warning";; *) echo "FAIL flow roundCap $v: no warning"; FAIL=1;; esac
done
jq '.settings.flow = {workerReportBody: "short"}' "$C" > "$TMP/f3.json"
SW="$(WM "$TMP/f3.json" 2>&1)"
case "$SW" in *"replaces the"*"at most ~8 lines"*"your scratchDir"*"Your ask and escalation messages stay full sentences."*) echo "ok   flow short: worker sentence";; *) echo "FAIL flow short worker: $SW"; FAIL=1;; esac
case "$(PM "$TMP/f3.json" 2>&1)" in *"worker_done reports are short"*"file whose absolute path the body names"*) echo "ok   flow short: planner sentence";; *) echo "FAIL flow short planner"; FAIL=1;; esac
jq '.settings.flow = {workerReportBody: "full"}' "$C" > "$TMP/f4.json"
check "flow full: planner_msg unchanged" "$(PM "$TMP/f4.json" 2>&1)" "$BASEP"
check "flow full: worker_msg unchanged" "$(WM "$TMP/f4.json" 2>&1)" "$BASEW"
jq '.settings.flow = {workerReportBody: "medium"}' "$C" > "$TMP/f5.json"
check "flow medium: planner_msg unchanged" "$(PM "$TMP/f5.json" 2>/dev/null)" "$BASEP"
check "flow medium: worker_msg unchanged" "$(WM "$TMP/f5.json" 2>/dev/null)" "$BASEW"
case "$(WM "$TMP/f5.json" 2>&1 >/dev/null)$(PM "$TMP/f5.json" 2>&1 >/dev/null)" in *"settings.flow.workerReportBody must be"*) echo "ok   flow medium: warning";; *) echo "FAIL flow medium: no warning"; FAIL=1;; esac
check "clean.sh --msg of a worker carries the short-body sentence" "$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$TMP/f3.json" "$TMP/home/.orca-roles/bin/clean.sh" --msg dev 2>&1)" "$(cd "$TMP" && KIT="$TMP/home/.orca-roles" worker_msg "$TMP/f3.json" dev)"
case "$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$TMP/f3.json" "$TMP/home/.orca-roles/bin/clean.sh" --msg dev 2>&1)" in *"at most ~8 lines"*) echo "ok   clean.sh --msg: short-body sentence";; *) echo "FAIL clean.sh --msg: no short-body sentence"; FAIL=1;; esac
rm -rf "$KIT/tmp"
}

sec_oracle() {
# Optional oracle: bin/oracle/*.py (acceptance command + test integrity) and bin/oracle.sh; planner_msg only changes with settings.oracle.enabled
OR="$TMP/or"; rm -rf "$OR"; mkdir -p "$OR/specs"
oracle_repo() {   # <name>: a git repo with a base commit on main (a test, a subject and its test), then branch feat
  local p="$OR/$1"; mkdir -p "$p/tests" "$p/src"
  git -C "$p" init -q; git -C "$p" checkout -q -b main 2>/dev/null || true
  git -C "$p" config user.email t@t; git -C "$p" config user.name t
  printf 'exit 0\n' > "$p/test.sh"; printf 'exit 0\n' > "$p/tests/a.sh"
  printf 'exit 0\n' > "$p/src/widget.sh"; printf 'exit 0\n' > "$p/tests/widget.test.sh"
  printf 'def test_x():\n    assert 1 == 1\n' > "$p/tests/test_b.py"; printf "it('a', () => {});\n" > "$p/tests/b.test.js"
  seq 1 30 | sed "s/.*/it('t&', () => {});/" > "$p/tests/big.test.js"
  git -C "$p" add -A; git -C "$p" commit -q -m base; git -C "$p" checkout -q -b feat
  printf '%s' "$p"
}
oracle_spec() {   # <acceptance block text> → spec file path
  local f; f="$(mktemp "$OR/specs/spec.XXXXXX")"
  printf '## Target\nmodule x\n## Change\nadd y\n## Constraints\nno network\n## Ownership\nsrc/**\n## Acceptance command\n%s\n' "$1" > "$f"; printf '%s' "$f"
}
oracle_run() {   # <repo> <task> <spec file> [extra args]: stdout in $OUT, exit code in $RC, stderr in $OR/err
  local p="$1" t="$2" s="$3"; shift 3
  try bash -c 'cd "$1" && ORCA_ROLES_ORACLE_OUT="$0" KIT="$2" HOME="$3" exec "$2/bin/oracle.sh" "${@:5}" 2>"$4"' "$OR/out" "$p" "$KIT" "$TMP/home" "$OR/err" --task "$t" --spec-file "$s" --no-wait "$@" 2>/dev/null
}
OCFG="$OR/cfg.json"; echo '{ "settings": { "oracle": { "enabled": true, "waitMax": 0 } } }' > "$OCFG"; export ORCA_ROLES_CONFIG="$OCFG"
# no python: exit 3 with a clear message (needs no python itself)
P0="$(oracle_repo nopy)"
try bash -c 'cd "$1" && ORCA_ROLES_PYTHON=no-such-python-xyz KIT="$2" HOME="$3" "$2/bin/oracle.sh" --task t0 --spec-file "$4" 2>"$5"' x "$P0" "$KIT" "$TMP/home" "$(oracle_spec '`bash test.sh`')" "$OR/err"
check "oracle.sh without python3 >= 3.8: exit 3" "$RC" "3"
case "$(cat "$OR/err")" in *"needs python3 >= 3.8"*) echo "ok   oracle.sh without python3: clear message";; *) echo "FAIL oracle.sh without python3: $(cat "$OR/err")"; FAIL=1;; esac
PYB="${ORCA_ROLES_PYTHON:-python3}"
if ! command -v "$PYB" >/dev/null 2>&1 || ! "$PYB" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
  echo "ok   oracle: skipped (no python3 >= 3.8)"
else
  PYF="$ROOT/bin/oracle"
  check "oracle: python files parse as python 3.8" "$("$PYB" -c 'import ast, sys; [ast.parse(open(f).read(), f, feature_version=(3, 8)) for f in sys.argv[1:]]; print("parsed")' "$PYF"/allow.py "$PYF"/spec_lint.py "$PYF"/verify_task.py 2>&1)" "parsed"
  st() { jq -r "$1" <<<"$OUT"; }
  # pass: exit 0, nothing written in the repo, verify.json under ORCA_ROLES_ORACLE_OUT
  P="$(oracle_repo pass)"; oracle_run "$P" t1 "$(oracle_spec '```
bash test.sh
```')"
  check "oracle pass: exit 0, status pass, no cheat" "$RC:$(st .status):$(st .pass):$(st .cheat)" "0:pass:true:false"
  check "oracle pass: verify.json written under ORCA_ROLES_ORACLE_OUT" "$(jq -r .status "$OR/out/t1/verify.json" 2>&1)" "pass"
  check "oracle pass: nothing written in the repo" "$(git -C "$P" status --porcelain)" ""
  check "oracle pass: config_sha is the sha1 of the config" "$(st .config_sha)" "$(shasum "$OCFG" | cut -d' ' -f1)"
  # fail, flaky, persistent red
  P="$(oracle_repo fail)"; printf 'exit 1\n' > "$P/test.sh"; oracle_run "$P" t2 "$(oracle_spec '`bash test.sh`')"
  check "oracle fail: exit 1, status fail, retried once (2 attempts)" "$RC:$(st .status):$(st .pass):$(st '.commands[0].attempts')" "1:fail:false:2"
  P="$(oracle_repo flaky)"; printf 'c=%s\nif [ -f "$c" ]; then exit 0; fi\ntouch "$c"; exit 1\n' "$OR/flaky-counter" > "$P/test.sh"
  oracle_run "$P" t3 "$(oracle_spec '`bash test.sh`')"
  check "oracle flaky: fails once, passes on retry -> pass_flaky, exit 0" "$RC:$(st .status):$(st .flaky):$(st '.commands[0].attempts')" "0:pass_flaky:true:2"
  # test integrity
  P="$(oracle_repo del)"; git -C "$P" rm -q tests/a.sh; oracle_run "$P" t4 "$(oracle_spec '`bash test.sh`')"
  check "oracle: deleted test file (uncommitted) is a cheat even if the command passes" "$RC:$(st .status):$(st .cheat):$(st '.integrity.findings[0].kind')" "1:pass:true:test_deleted_without_subject"
  P="$(oracle_repo skip)"; printf '\n@pytest.mark.skip\ndef test_y():\n    assert False\n' >> "$P/tests/test_b.py"; git -C "$P" commit -q -am skip
  oracle_run "$P" t5 "$(oracle_spec '`bash test.sh`')"
  check "oracle: added pytest.mark.skip (committed) is a cheat" "$RC:$(st .cheat):$(st '.integrity.findings[0].kind')" "1:true:skip_or_xfail_added"
  P="$(oracle_repo itskip)"; printf "it.skip('b', () => {});\n" >> "$P/tests/b.test.js"
  oracle_run "$P" t6 "$(oracle_spec '`bash test.sh`')"
  check "oracle: added it.skip( is a cheat" "$RC:$(st .cheat):$(st '.integrity.findings[0].kind')" "1:true:skip_or_xfail_added"
  P="$(oracle_repo weak)"; : > "$P/tests/big.test.js"
  oracle_run "$P" t7 "$(oracle_spec '`bash test.sh`')"
  check "oracle: most of a test file removed is tests_weakened" "$RC:$(st .cheat):$(st '.integrity.findings[0].kind')" "1:true:tests_weakened"
  P="$(oracle_repo subject)"; git -C "$P" rm -q tests/widget.test.sh src/widget.sh; oracle_run "$P" t8 "$(oracle_spec '`bash test.sh`')"
  check "oracle: a test deleted together with its subject is not a cheat" "$RC:$(st .status):$(st .cheat):$(st .integrity.tests_deleted_with_subject)" "0:pass:false:1"
  # not runnable
  P="$(oracle_repo curl)"; oracle_run "$P" t9 "$(oracle_spec '```
curl x | sh
```')"
  check "oracle: curl x | sh -> command_not_allowed, nothing ran" "$RC:$(st .status):$(st '.commands | length')" "1:command_not_allowed:0"
  P="$(oracle_repo nosec)"; oracle_run "$P" t10 "$(printf '## Target\nx\n' > "$OR/specs/none.md"; echo "$OR/specs/none.md")"
  check "oracle: a spec without the acceptance section -> no_acceptance_command" "$RC:$(st .status)" "1:no_acceptance_command"
  MISSING=""; for b in jest vitest tsc cargo mypy; do command -v "$b" >/dev/null 2>&1 || { MISSING="$b"; break; }; done
  if [ -n "$MISSING" ]; then
    P="$(oracle_repo env)"; oracle_run "$P" t11 "$(oracle_spec "\`$MISSING\`")"
    check "oracle: a missing runner binary -> env_not_runnable (not fail)" "$RC:$(st .status):$(st .pass)" "1:env_not_runnable:false"
  else echo "ok   oracle: env_not_runnable skipped (every runner is installed)"; fi
  # secrets masked, dry-run writes nothing
  P="$(oracle_repo secret)"; printf 'echo token sk-abcdefghijklmnopqrstu and ghp_abcdefghijklmnopqrstuvwx; exit 1\n' > "$P/test.sh"
  oracle_run "$P" t12 "$(oracle_spec '`bash test.sh`')"
  case "$(st '.commands[0].tail')" in *sk-abc*|*ghp_abc*) echo "FAIL oracle: a secret reached the output"; FAIL=1;; *"[REDACTED]"*) echo "ok   oracle: secrets in the output are masked";; *) echo "FAIL oracle: secrets: $(st '.commands[0].tail')"; FAIL=1;; esac
  case "$(cat "$OR/out/t12/verify.json")" in *sk-abc*) echo "FAIL oracle: a secret reached verify.json"; FAIL=1;; *) echo "ok   oracle: verify.json has no secret";; esac
  P="$(oracle_repo dry)"; oracle_run "$P" t13 "$(oracle_spec '`bash test.sh`')" --dry-run
  check "oracle --dry-run: status dry_run, no verify.json, nothing ran" "$(st .status):$([ -e "$OR/out/t13" ] && echo written || echo none):$(st '.commands[0] | has("exit")')" "dry_run:none:false"
  # the wrapper: settings.oracle, config lookup, provenance, warning
  P="$(oracle_repo wrap)"; printf 'exit 1\n' > "$P/test.sh"; S="$(oracle_spec '`bash test.sh`')"
  echo '{ "settings": { "oracle": { "enabled": true, "waitMax": 0, "retries": 2 } } }' > "$OCFG"
  oracle_run "$P" w1 "$S"; check "oracle.sh passes settings.oracle.retries (2 retries = 3 attempts)" "$(st '.commands[0].attempts')" "3"
  case "$(cat "$OR/err")" in *"not true"*) echo "FAIL oracle.sh warns although enabled"; FAIL=1;; *) echo "ok   oracle.sh: no warning when enabled";; esac
  printf '%s\n' '{"role":"dev","agent":"claude","model":"old-model"}' '{"role":"tester","agent":"codex","model":"tm"}' '{"role":"dev","agent":"opencode","model":"prov/m-dev"}' > "$P/.git/orca-roles.provenance.jsonl"
  oracle_run "$P" w2 "$S"; check "oracle.sh passes agent and model of the last dev provenance line" "$(st .agent):$(st .model)" "opencode:prov/m-dev"
  echo '{ "settings": { "oracle": { "enabled": false, "waitMax": 0, "retries": 0 } } }' > "$OCFG"
  oracle_run "$P" w3 "$S"; check "oracle.sh: retries 0 = 1 attempt" "$(st '.commands[0].attempts')" "1"
  case "$(cat "$OR/err")" in *"settings.oracle.enabled is not true"*) echo "ok   oracle.sh: warns on stderr when disabled but runs";; *) echo "FAIL oracle.sh: no warning when disabled: $(cat "$OR/err")"; FAIL=1;; esac
  unset ORCA_ROLES_CONFIG
  echo '{ "settings": { "oracle": { "enabled": true, "waitMax": 0, "retries": 0 } } }' > "$P/.git/orca-roles.config.json"
  oracle_run "$P" w4 "$S"; check "oracle.sh reads <git dir>/orca-roles.config.json without ORCA_ROLES_CONFIG" "$(st '.commands[0].attempts')" "1"
  rm -f "$P/.git/orca-roles.config.json"
  oracle_run "$P" w5 "$S"; check "oracle.sh with no config file: merged config defaults (retries 1 = 2 attempts)" "$(st '.commands[0].attempts')" "2"
  case "$(cat "$OR/err")" in *"not true"*) echo "ok   oracle.sh: default config is off, so it warns";; *) echo "FAIL oracle.sh: default config did not warn"; FAIL=1;; esac
  export ORCA_ROLES_CONFIG="$OCFG"
fi
unset ORCA_ROLES_CONFIG
# config: the defaults, and a user's values survive upgrade_config
check "default config: settings.oracle is off with the documented defaults" "$(jq -c '.settings.oracle' "$ROOT/config.default.json")" '{"enabled":false,"maxLoad":0.8,"waitMax":300,"timeout":600,"retries":1}'
echo '{ "settings": { "oracle": { "enabled": true, "maxLoad": 0.5 } }, "roles": {} }' > "$OR/user.json"
check "upgrade_config keeps the user's settings.oracle values and fills the rest" "$(upgrade_config "$ROOT/config.default.json" "$OR/user.json" | jq -c '.settings.oracle')" '{"enabled":true,"maxLoad":0.5,"waitMax":300,"timeout":600,"retries":1}'
# planner_msg: the sentence only with settings.oracle.enabled in programmer mode
clean_fixture
printf 'PLANNER=t1\nDEV=t2\n' > "$TMP/state.env"
PM() { planner_msg "$1" "planner dev" "$TMP/state.env" "" "" 0 2>&1; }
BASEP="$(PM "$C")"
jq '.settings.oracle = {enabled: false}' "$C" > "$OR/o0.json"; check "oracle disabled: planner_msg unchanged" "$(PM "$OR/o0.json")" "$BASEP"
jq '.settings.oracle = {}' "$C" > "$OR/o1.json"; check "oracle {} (no enabled): planner_msg unchanged" "$(PM "$OR/o1.json")" "$BASEP"
jq '.settings.oracle = {enabled: "yes"}' "$C" > "$OR/o2.json"; check "oracle enabled not true (a string): planner_msg unchanged" "$(PM "$OR/o2.json")" "$BASEP"
jq '.settings.oracle = {enabled: true}' "$C" > "$OR/o3.json"; OM="$(PM "$OR/o3.json")"
case "$OM" in *'## Acceptance command'*"spec-<task_id>.md"*"$(kit_env)$KIT/bin/oracle.sh --task <task_id> --spec-file <that file>"*"The Tester's VERDICT stays, but the oracle decides"*) echo "ok   oracle enabled in programmer: planner_msg carries the sentence";; *) echo "FAIL oracle planner sentence: $OM"; FAIL=1;; esac
case "$OM" in "${BASEP%Start with the startup.}"*"Start with the startup.") echo "ok   oracle enabled: the usual message and its ending are kept";; *) echo "FAIL oracle: message lost its usual parts"; FAIL=1;; esac
jq '.settings.mode = "pr-reviewer"' "$C" > "$OR/p0.json"; jq '.settings.mode = "pr-reviewer" | .settings.oracle = {enabled: true}' "$C" > "$OR/p1.json"
check "oracle enabled in pr-reviewer: planner_msg unchanged" "$(PM "$OR/p1.json")" "$(PM "$OR/p0.json")"
rm -rf "$OR"
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
}

sec_cleanup_msg() {
clean_fixture
# Role field "common": names that file instead of common-workers.md; a missing file falls back with a warning; clean.sh --msg agrees
mkdir -p "$KIT/prompts/programmer"; echo peon > "$KIT/prompts/programmer/common-peon.md"
jq '.roles.dev.common = "{kit}/prompts/programmer/common-peon.md"' "$C" > "$TMP/cmn.json"
check "worker_msg with common: names that file" "$(cd "$TMP" && worker_msg "$TMP/cmn.json" dev 2>&1 | grep -o '^Read [^ ]* and [^ ]*')" "Read $KIT/prompts/programmer/common-peon.md and $KIT/prompts/programmer/dev.md"
check "worker_msg with common: the rest of the message is unchanged" "$(cd "$TMP" && worker_msg "$TMP/cmn.json" dev | sed 's#common-peon.md#common-workers.md#')" "$(cd "$TMP" && worker_msg "$C" dev)"
jq '.roles.dev.common = "~/nope/common.md"' "$C" > "$TMP/cmn2.json"
check "worker_msg with a missing common file: falls back to common-workers.md" "$(cd "$TMP" && worker_msg "$TMP/cmn2.json" dev 2>/dev/null)" "$(cd "$TMP" && worker_msg "$C" dev)"
case "$(cd "$TMP" && worker_msg "$TMP/cmn2.json" dev 2>&1 >/dev/null)" in *"common file of role 'dev' does not exist"*"using common-workers.md"*) echo "ok   worker_msg with a missing common file: warning on stderr";; *) echo "FAIL worker_msg missing common: no warning"; FAIL=1;; esac
check "worker_msg with common: other roles are unchanged" "$(cd "$TMP" && worker_msg "$TMP/cmn.json" cx)" "$(cd "$TMP" && worker_msg "$C" cx)"
check "clean.sh --msg of a worker with common is its role message" "$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_STATE="$TMP/state.env" ORCA_ROLES_CONFIG="$TMP/cmn.json" "$TMP/home/.orca-roles/bin/clean.sh" --msg dev 2>&1)" "$(cd "$TMP" && KIT="$TMP/home/.orca-roles" worker_msg "$TMP/cmn.json" dev)"
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
# the default pinned playwright entry, expanded for claude (mcp file) and codex (-c overrides)
cp "$ROOT/config.default.json" "$TMP/pwdef.json"
( role_context "$TMP/pwdef.json" e2e-tester "$PROJ"
  mcp_file "$TMP/pwdef.json" e2e-tester > "$TMP/pwdef-mcp.json"
  check "default playwright entry: command and env expand from the kit for claude" "$(jq -r '.mcpServers.playwright | [.command, .env.PLAYWRIGHT_BROWSERS_PATH] | join(" ")' "$TMP/pwdef-mcp.json")" "$KIT/pw/node_modules/.bin/playwright-mcp $KIT/browsers"
  check "default playwright entry: args pick chromium, with session and evidence expanded" "$(jq -c '.mcpServers.playwright.args[0:2], (.mcpServers.playwright.args | index("{browserState}"), index("{worktree}/{evidenceDir}"))' "$TMP/pwdef-mcp.json" | tr '\n' ' ')" '["--browser","chromium"] null null '
  OVR="$(codex_mcp_overrides "$TMP/pwdef-mcp.json" | grep '^mcp_servers.playwright' | tr '\n' '|')"
  case "$OVR" in
    'mcp_servers.playwright.command="'"$KIT"'/pw/node_modules/.bin/playwright-mcp"|mcp_servers.playwright.args=["--browser","chromium","--headless","--isolated","--storage-state","'"$KIT"'/browser/'*'.json","--output-dir","'*'"]|mcp_servers.playwright.env={PLAYWRIGHT_BROWSERS_PATH = "'"$KIT"'/browsers"}|') echo "ok   default playwright entry: codex overrides carry command, args and env";;
    *) echo "FAIL default playwright entry for codex: $OVR"; FAIL=1;;
  esac
  [ "$FAIL" = 0 ] ) || FAIL=1
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
  check "role_context: browser state per project" "$ORCA_ROLES_BROWSER_STATE" "$KIT/browser/proj/default.json"
  A="$(mcp_file "$C" vt | jq -c '.mcpServers.pw.args')"
  check "mcp_file expands placeholders in args" "$A" "[\"-y\",\"@playwright/mcp@latest\",\"--headless\",\"--storage-state\",\"$KIT/browser/proj/default.json\",\"--output-dir\",\"$(cd "$PROJ" && pwd)/ev\"]"
  check "mcp_file expands in env and url" "$(mcp_file "$C" vt | jq -r '.mcpServers.pw.env.P + " " + .mcpServers.pw.env.K + " " + .mcpServers.h.url')" "proj $KIT http://$HOME/x"
  [ "$FAIL" = 0 ] ) || FAIL=1
( role_context "$C" other "$PROJ"; check "role_context: default evidenceDir" "$ORCA_ROLES_EVIDENCE_DIR" "qa-evidence"; [ "$FAIL" = 0 ] ) || FAIL=1
OUT="$(cd "$PROJ" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$C" "$TMP/home/.orca-roles/bin/agent.sh" vt 2>&1)"; F="${OUT#run }"
check "agent.sh creates the empty browser state" "$(cat "$TMP/home/.orca-roles/browser/proj/default.json" 2>/dev/null)" '{"cookies":[],"origins":[]}'
check "agent.sh: MCP file with expanded placeholders" "$(jq -r '.mcpServers.pw.args[4]' "$F" 2>/dev/null)" "$TMP/home/.orca-roles/browser/proj/default.json"
echo '{"cookies":[{"n":1}],"origins":[]}' > "$KIT/browser/proj/default.json"
( role_context "$C" vt "$PROJ"; ensure_browser_state "$ORCA_ROLES_BROWSER_STATE"; check "ensure_browser_state does not overwrite an existing session" "$(jq -c '.cookies | length' "$KIT/browser/proj/default.json")" "1"; [ "$FAIL" = 0 ] ) || FAIL=1
grep -q -- '--headless' "$ROOT/config.default.json" && grep -q '{browserState}' "$ROOT/config.default.json" && grep -q '{worktree}/{evidenceDir}' "$ROOT/config.default.json" && echo "ok   config.default: headless playwright with session and evidence" || { echo "FAIL config.default playwright"; FAIL=1; }
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
check "shim: 'orca' calls ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide KIT="$KIT" bash -c '. "$KIT/bin/lib.sh"; orca terminal list')" "orca-ide:terminal list"
rm -f "$KIT/shim/orca"
check "shim: not created without ORCA_CLI_COMMAND" "$(PATH="$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND='' KIT="$KIT" bash -c '. "$KIT/bin/lib.sh"; command -v orca || echo none')" "none"
check "shim: not created if 'orca' already exists" "$(PATH="$TMP/fakebin:$TMP/cli:/usr/bin:/bin" ORCA_CLI_COMMAND=orca-ide KIT="$KIT" bash -c 'printf "#!/bin/sh\n" > "$0/orca"; chmod +x "$0/orca"; . "$KIT/bin/lib.sh"; command -v orca' "$TMP/fakebin")" "$TMP/fakebin/orca"
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
yreset; hsjson local-only "npm i" > "$YP"; yrun; check "roles-yaml error goes to stderr; the only stdout line is the result" "$(env -u ORCA_CLI_COMMAND PATH="$FB:/usr/bin:/bin" FAKE_LOG="$YLOG" FAKE_PATH="$YP" bash -c 'cd "$0" && "$1/bin/orca-yaml.sh" 2>/dev/null' "$Y2" "$ROOT")" "ROLES_YAML_RESULT=skipped:local-only-policy"

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
yrun2() { try env KIT="$KIT" PATH="$FB2:/usr/bin:/bin" ORCA_CLI_COMMAND="$1" FAKE_LOG="$YLOG" FAKE_PATH="$YP" FAKE_WT="$YW" FAKE_ID="$YI" \
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
try yaml "$TMP/ywt" --help; check "roles-yaml --help lists --check" "$RC:$(printf '%s\n' "$OUT" | grep -c -e '--check'):$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "0:1:11"
check "roles-yaml --help lists --mode, --all, --under, --dry-run and the result line" "$(printf '%s\n' "$OUT" | grep -c -e '--mode'):$(printf '%s\n' "$OUT" | grep -c -e '--all'):$(printf '%s\n' "$OUT" | grep -c -e '--under'):$(printf '%s\n' "$OUT" | grep -c -e '--dry-run'):$(printf '%s\n' "$OUT" | grep -c ROLES_YAML_RESULT)" "5:1:2:1:1"
yreset; printf 'garbage' > "$YP"; yrun --check; check "roles-yaml --check: unexpected output is silent" "$RC:$OUT" "0:"
mkdir -p "$TMP/ynogit"; try env PATH="$FB:/usr/bin:/bin" bash -c 'cd "$0" && GIT_CEILING_DIRECTORIES="$0/.." "$1/bin/orca-yaml.sh" --check 2>&1' "$TMP/ynogit" "$ROOT"; check "roles-yaml --check: outside a git repo is silent" "$RC:$OUT" "0:"

# roles-yaml --mode: the setup line carries the mode; rerun updates, drops or leaves it; nothing foreign is touched
Y3="$TMP/ymode"; mkdir -p "$Y3"; git -C "$Y3" init -q; git -C "$Y3" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
ym() { try yaml "$Y3" "$@"; }
ysetup() { sed -n 's/^    //p' "$Y3/orca.yaml" | tr '\n' '|'; }
yfiles3() { { shasum "$Y3/orca.yaml" "$Y3/.worktreeinclude" "$Y3/.git/info/exclude" 2>&1; ls -A "$Y3"; } | tr '\n' ' '; }
yreset3() { rm -f "$Y3/orca.yaml" "$Y3/.worktreeinclude"; : > "$Y3/.git/info/exclude"; git -C "$Y3" rm -q -f --cached orca.yaml 2>/dev/null || true; }
has() { case "$OUT" in *"$1"*) printf y;; *) printf n;; esac; }
LM='$HOME/.orca-roles/bin/launch.sh --mode'
ym --mode pr-reviewer
check "roles-yaml --mode: creates the line, ignored, closing lines" "$RC:$(ysetup):$(git -C "$Y3" status --porcelain):$(has 'Created '):$(has 'New worktrees of this project start in mode pr-reviewer'):$(has 'Existing worktrees keep their mode: use roles --mode <mode> in them.')" "0:$LM pr-reviewer|::y:y:y"
S3="$(yfiles3)"; M=""
ym --mode pr-reviewer; M="$M same:$RC:$(has 'Nothing changed'):$(has Updated):$(has 'New worktrees of this project'):$([ "$(yfiles3)" = "$S3" ] && echo same || echo diff);"
ym --mode academic-research; M="$M other:$RC:$(ysetup):$(has 'Updated '):$(has 'start in mode academic-research'):$(has 'Existing worktrees keep'):$(grep -c launch.sh "$Y3/orca.yaml");"
ym --mode programmer; M="$M prog:$RC:$(ysetup);"
ym --mode pr-reviewer --mode academic-research; M="$M last:$RC:$(ysetup);"
ym; M="$M drop:$RC:$(ysetup):$(has 'Updated '):$(has 'default mode (settings.mode');"
ym; M="$M again:$RC:$(has 'Nothing changed'):$(has 'default mode');"
check "roles-yaml --mode: rerun same, another, repeated, dropped, default again" "$M" " same:0:y:n:n:same; other:0:$LM academic-research|:y:y:y:1; prog:0:$LM programmer|; last:0:$LM academic-research|; drop:0:\$HOME/.orca-roles/bin/launch.sh|:y:y; again:0:y:y;"
yreset3; ym --mode pr-reviewer; ym --remove; check "roles-yaml --remove after --mode removes it" "$RC:$(ls -A "$Y3" | tr '\n' ' ')" "0:.git "
M=""; for v in bogus Programmer PR-REVIEWER ../x "pr reviewer" a/b; do
  yreset3; ym --mode "$v"; M="$M$RC:$(ls -A "$Y3" | tr '\n' ' '):$(has 'modes: programmer, pr-reviewer, academic-research'):$(has 'Nothing was written');"
done
yreset3; ym --mode; M="$M$RC:$(ls -A "$Y3" | tr '\n' ' ');"
yreset3; ym --mode ""; M="$M$RC:$(ls -A "$Y3" | tr '\n' ' ');"
yreset3; ym --mode --remove; M="$M$RC:$(ls -A "$Y3" | tr '\n' ' ');"
yreset3; ym; S3="$(yfiles3)"; ym --mode bogus; M="$M$RC:$([ "$(yfiles3)" = "$S3" ] && echo same || echo diff)"
check "roles-yaml --mode: invalid, missing, empty values stop and write nothing" "$M" "$(for i in 1 2 3 4 5 6; do printf '1:.git :y:y;'; done)1:.git ;1:.git ;1:.git ;1:same"
M=""; for a in "--mode pr-reviewer --remove" "--remove --mode pr-reviewer" "--mode pr-reviewer --check" "--check --mode pr-reviewer" "--remove --check"; do
  ym $a; M="$M$RC:$([ "$(yfiles3)" = "$S3" ] && echo same || echo diff);"
done
check "roles-yaml --mode: with --remove/--check, and --remove --check, is a usage error" "$M" "1:same;1:same;1:same;1:same;1:same;"
yreset3; printf 'scripts:\n  setup: npm i\n' > "$Y3/orca.yaml"; M=""
ym --mode pr-reviewer; M="$M$RC:$(tr '\n' ' ' < "$Y3/orca.yaml"):$(has "the line $LM pr-reviewer,");"
ym; M="$M$RC:$(has 'the line $HOME/.orca-roles/bin/launch.sh, or'):$(has '--mode');"
git -C "$Y3" add -f orca.yaml; git -C "$Y3" -c user.name=t -c user.email=t@t commit -q -m yaml
ym --mode academic-research; M="$M$RC:$(tr '\n' ' ' < "$Y3/orca.yaml"):$(has "$LM academic-research"):$(has committed):$(git -C "$Y3" status --porcelain)"
check "roles-yaml --mode: foreign and committed orca.yaml are left alone, advice shows --mode" "$M" "1:scripts:   setup: npm i :y;1:y:n;1:scripts:   setup: npm i :y:y:"
git -C "$Y3" rm -q -f orca.yaml; git -C "$Y3" -c user.name=t -c user.email=t@t commit -q -m rm-yaml
KIT_YM="scripts:"$'\n'"  setup: |"$'\n'"    \$HOME/.orca-roles/bin/launch.sh --mode pr-reviewer"$'\n'
M=""
ychk shared-only "npm i" "" "$KIT_YM" orca.yaml; M="$M$RC:$OUT|"
ychk run-both "$KITL" "" "$KIT_YM" orca.yaml; M="$M$RC:$OUT|"
ychk shared-only "npm i" "" "scripts:"$'\n'"  setup: |"$'\n'"    # \$HOME/.orca-roles/bin/launch.sh --mode pr-reviewer"$'\n' orca.yaml; M="$M$RC:$OUT"
check "roles-yaml --check: a --mode line counts as the kit (silent, twice, commented does not)" "$M" "0:|0:$W_TWICE|0:$W_SHARED"
yreset; hsjson shared-only "npm i" > "$YP"; yrun --mode pr-reviewer; M="$RC:$(sed -n 's/^    //p' "$Y2/orca.yaml")"
yreset; hsjson local-only "npm i" > "$YP"; yrun --mode pr-reviewer; M="$M:$(yclass)"
check "roles-yaml --mode: with a fake policy, shared-only writes the line and local-only without the kit stops" "$M" "0:$LM pr-reviewer:a"

# roles-yaml --all: every result class with scratch repos and a stub 'orca' (repo list / repo show); nothing real is touched
YA="$TMP/yall"; rm -rf "$YA"; mkdir -p "$YA/u" "$YA/plain" "$YA/bin" "$YA/show"
for n in fresh reg committed u/a-b u/a-bc askp lo ro; do mkdir -p "$YA/$n"; git -C "$YA/$n" init -q; git -C "$YA/$n" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; done
git -C "$YA/fresh" worktree add -q "$YA/wt" -b ywtb 2>/dev/null; mkdir -p "$YA/fresh/nested"
printf 'scripts:\n  setup: npm i\n' > "$YA/committed/orca.yaml"; git -C "$YA/committed" add -f orca.yaml; git -C "$YA/committed" -c user.name=t -c user.email=t@t commit -q -m yaml
cat > "$YA/bin/orca" <<'FEOF'
#!/bin/sh
case "$1 $2" in
  "repo list") [ -z "${FAKE_LIST_RC:-}" ] || exit "$FAKE_LIST_RC"; cat "$FAKE_LIST";;
  "repo show") p="${4#path:}"; f="$FAKE_SHOW/$(basename "$p")"; [ -f "$f" ] && cat "$f" || exit 1;;
  *) exit 1;;
esac
FEOF
chmod +x "$YA/bin/orca"
printf '{"ok":true,"result":{"repo":{"hookSettings":{"setupRunPolicy":"ask"}}}}' > "$YA/show/askp"
printf '{"ok":true,"result":{"repo":{"hookSettings":{"commandSourcePolicy":"local-only","scripts":{"setup":"npm i"}}}}}' > "$YA/show/lo"
yall_list() { jq -nc --arg d "$YA" '{ok:true,result:{repos:([
  ["fresh","fresh"],["reg","reg"],["committed","committed"],["plain","plain"],["missing","missing"],["wt","wt"],["nested","fresh/nested"],["a-b","u/a-b"],["a-bc","u/a-bc"],["fresh-again","fresh"],["askp","askp"],["lo","lo"]
  ] | map({displayName:.[0], path:($d + "/" + .[1]), kind:"git", gitUsername:"SECRET-USER", projectGroupId:"g"}))}}' > "$YA/list.json"; }
yall_list
yallrun() { try env PATH="$YA/bin:$PATH" FAKE_LIST="$YA/list.json" FAKE_SHOW="$YA/show" FAKE_LIST_RC="${FAKE_LIST_RC:-}" "$ROOT/bin/orca-yaml.sh" "$@" 2>/dev/null; }
yallerr() { ERR="$(env PATH="$YA/bin:$PATH" FAKE_LIST="$YA/list.json" FAKE_SHOW="$YA/show" FAKE_LIST_RC="${FAKE_LIST_RC:-}" "$ROOT/bin/orca-yaml.sh" "$@" 2>&1 >/dev/null)" && RC=0 || RC=$?; OUT="$ERR"; }
ytree() { (cd "$YA" && find . -type f -not -path './bin/*' -not -path './show/*' -not -name list.json | LC_ALL=C sort | xargs shasum; find . -type d | LC_ALL=C sort; git -C "$YA/fresh" status --porcelain --ignored) | shasum; }
yl() { printf '%s (%s/%s): %s\n' "$1" "$YA" "$2" "$3"; }
W_ASK="  WARNING: this project's setup policy is 'ask': Orca asks each time, and 'orca worktree create' needs '--setup run'. The kit does not start by itself."
# setup of the already-registered project: a mode set earlier with the single path
yaml "$YA/reg" --mode pr-reviewer >/dev/null
T0="$(ytree)"
yallrun --all --dry-run
EXP="$(yl fresh fresh 'would create'; yl reg reg 'unchanged (mode pr-reviewer kept)'; yl committed committed 'skipped: committed-orca-yaml'; echo "  ERROR: this project already has a committed orca.yaml. Add to its 'scripts: setup:' the line"; yl plain plain 'skipped: not-a-repo'; yl missing missing 'skipped: path-missing'; yl wt wt 'skipped: not-main-checkout'; yl nested fresh/nested 'skipped: not-main-checkout'; yl a-b u/a-b 'would create'; yl a-bc u/a-bc 'would create'; yl fresh-again fresh 'skipped: already-listed'; yl askp askp 'would create'; echo "$W_ASK"; yl lo lo 'skipped: local-only-policy'; echo "  ERROR: this project's setup source is local-only"'*'; echo 'Summary: 4 created, 0 updated, 1 unchanged, 7 skipped, 0 errors'; echo 'Dry run: nothing was written.')"
ACT="$(printf '%s\n' "$OUT" | sed 's/^\(  ERROR: this project.s setup source is local-only\).*/\1*/')"
check "roles-yaml --all --dry-run: a line per project, every skip reason, warning indented, summary" "$RC:$ACT" "0:$EXP"
check "roles-yaml --all --dry-run: nothing written anywhere (tree, exclude, status byte-identical)" "$(ytree)" "$T0"
check "roles-yaml --all: the output never carries gitUsername" "$(printf '%s' "$OUT" | grep -c SECRET-USER || true)" "0"
yallrun --all
EXP2="$(printf '%s\n' "$EXP" | sed -e 's/would create/created/' -e '$d' | sed -e 's/Summary: 4 created, 0 updated, 1 unchanged, 7 skipped/Summary: 4 created, 0 updated, 1 unchanged, 7 skipped/' | sed '/^fresh-again/s/created/skipped: already-listed/')"
ACT="$(printf '%s\n' "$OUT" | sed 's/^\(  ERROR: this project.s setup source is local-only\).*/\1*/')"
check "roles-yaml --all: created / unchanged (mode kept) / skipped, no 'Dry run' line" "$RC:$ACT" "0:$EXP2"
check "roles-yaml --all: orca.yaml only where created, the registered mode is kept, the committed one untouched" "$(for n in fresh reg committed plain u/a-b u/a-bc askp lo wt; do printf '%s=%s;' "$n" "$(sed -n 's/^    //p' "$YA/$n/orca.yaml" 2>/dev/null | tr '\n' '|')"; done)" "fresh=\$HOME/.orca-roles/bin/launch.sh|;reg=\$HOME/.orca-roles/bin/launch.sh --mode pr-reviewer|;committed=;plain=;u/a-b=\$HOME/.orca-roles/bin/launch.sh|;u/a-bc=\$HOME/.orca-roles/bin/launch.sh|;askp=\$HOME/.orca-roles/bin/launch.sh|;lo=;wt=;"
check "roles-yaml --all: nothing to commit in the created projects" "$(git -C "$YA/fresh" status --porcelain)$(git -C "$YA/u/a-b" status --porcelain)" ""
yallrun --all --dry-run; check "roles-yaml --all --dry-run after --all: unchanged lines" "$RC:$(printf '%s\n' "$OUT" | grep -c 'unchanged (default mode kept)')/$(printf '%s\n' "$OUT" | grep -c 'unchanged (mode pr-reviewer kept)')/$(printf '%s\n' "$OUT" | grep '^Summary')" "0:4/1/Summary: 0 created, 0 updated, 5 unchanged, 7 skipped, 0 errors"
yallrun --all; check "roles-yaml --all rerun: nothing created or updated" "$RC:$(printf '%s\n' "$OUT" | grep '^Summary')" "0:Summary: 0 created, 0 updated, 5 unchanged, 7 skipped, 0 errors"
# a registration with a missing line (.worktreeinclude or info/exclude) is repaired in place, the mode kept
yrl() { printf '%s\n' "$OUT" | grep "^$1 ("; }
grep -vxF orca.yaml "$YA/reg/.worktreeinclude" > "$YA/wi.tmp"; cp "$YA/wi.tmp" "$YA/reg/.worktreeinclude"
grep -vxF orca.yaml "$YA/u/a-b/.git/info/exclude" > "$YA/ex.tmp"; cp "$YA/ex.tmp" "$YA/u/a-b/.git/info/exclude"
T3="$(ytree)"
yallrun --all --dry-run
check "roles-yaml --all --dry-run: a missing .worktreeinclude / exclude line says would repair (mode kept), writes nothing" "$RC:$(yrl reg):$(yrl a-b):$(printf '%s\n' "$OUT" | grep '^Summary'):$([ "$(ytree)" = "$T3" ] && echo same || echo diff)" "0:reg ($YA/reg): would repair (mode pr-reviewer kept):a-b ($YA/u/a-b): would repair (default mode kept):Summary: 0 created, 2 updated, 3 unchanged, 7 skipped, 0 errors:same"
yallrun --all
check "roles-yaml --all: repairs the missing line, keeps the mode, counts as updated" "$RC:$(yrl reg):$(yrl a-b):$(printf '%s\n' "$OUT" | grep '^Summary'):$(grep -cx orca.yaml "$YA/reg/.worktreeinclude"):$(git -C "$YA/u/a-b" check-ignore orca.yaml):$(sed -n 's/^    //p' "$YA/reg/orca.yaml"):$(sed -n 's/^    //p' "$YA/u/a-b/orca.yaml")" "0:reg ($YA/reg): repaired (mode pr-reviewer kept):a-b ($YA/u/a-b): repaired (default mode kept):Summary: 0 created, 2 updated, 3 unchanged, 7 skipped, 0 errors:1:orca.yaml:\$HOME/.orca-roles/bin/launch.sh --mode pr-reviewer:\$HOME/.orca-roles/bin/launch.sh"
yallrun --all
check "roles-yaml --all after a repair: unchanged again" "$RC:$(yrl reg):$(yrl a-b):$(printf '%s\n' "$OUT" | grep '^Summary')" "0:reg ($YA/reg): unchanged (mode pr-reviewer kept):a-b ($YA/u/a-b): unchanged (default mode kept):Summary: 0 created, 0 updated, 5 unchanged, 7 skipped, 0 errors"
T1="$(ytree)"
yallrun --all --mode academic-research --dry-run
check "roles-yaml --all --mode --dry-run: would update to mode X everywhere, writes nothing" "$RC:$(printf '%s\n' "$OUT" | grep -c 'would update to mode academic-research'):$(printf '%s\n' "$OUT" | grep '^Summary'):$([ "$(ytree)" = "$T1" ] && echo same || echo diff)" "0:5:Summary: 0 created, 5 updated, 0 unchanged, 7 skipped, 0 errors:same"
yallrun --all --mode academic-research
check "roles-yaml --all --mode: updates every registered project (also the one in another mode)" "$RC:$(printf '%s\n' "$OUT" | grep -c ': updated to mode academic-research$'):$(printf '%s\n' "$OUT" | grep '^Summary'):$(grep -c 'launch.sh --mode academic-research' "$YA/reg/orca.yaml" "$YA/fresh/orca.yaml" "$YA/u/a-b/orca.yaml" "$YA/askp/orca.yaml" | tr '\n' ' ')" "0:5:Summary: 0 created, 5 updated, 0 unchanged, 7 skipped, 0 errors:$(for n in reg fresh u/a-b askp; do printf '%s/%s/orca.yaml:1 ' "$YA" "$n"; done)"
check "roles-yaml --all --mode: the committed orca.yaml is still skipped and untouched" "$(printf '%s\n' "$OUT" | grep -c 'committed-orca-yaml'):$(tr '\n' ' ' < "$YA/committed/orca.yaml"):$(git -C "$YA/committed" status --porcelain)" "1:scripts:   setup: npm i :"
yallrun --all --mode programmer --under "$YA/u/a-b"
check "roles-yaml --all --under: only the folder itself, never the look-alike sibling a-bc" "$RC:$(printf '%s\n' "$OUT" | wc -l | tr -d ' '):$(printf '%s\n' "$OUT" | grep -c '/a-b):'):$(printf '%s\n' "$OUT" | grep -c 'a-bc'):$(grep -c 'academic-research' "$YA/u/a-bc/orca.yaml"):$(grep -c 'programmer' "$YA/u/a-b/orca.yaml")" "0:2:1:0:1:1"
yallrun --all --dry-run --under "$YA/u/"; check "roles-yaml --all --under: a folder with a trailing slash matches its children, not the rest" "$RC:$(printf '%s\n' "$OUT" | grep -c '^a-bc\? ('):$(printf '%s\n' "$OUT" | grep -c '^fresh ')" "0:2:0"
yallrun --all --dry-run --under "$YA/fresh"; check "roles-yaml --all --under: a project folder includes the project and what is nested in it" "$RC:$(printf '%s\n' "$OUT" | grep -c '^fresh \|^nested \|^fresh-again '):$(printf '%s\n' "$OUT" | grep -c '^reg ')" "0:3:0"
# error class: a project whose orca.yaml path is a directory (fails for any user, root included)
mkdir "$YA/ro/orca.yaml"; printf '%s\n' "$(jq -c '.result.repos += [{displayName:"ro",path:($d+"/ro"),kind:"git",gitUsername:"SECRET-USER"}]' --arg d "$YA" "$YA/list.json")" > "$YA/list.json"
yallrun --all; rmdir "$YA/ro/orca.yaml"
check "roles-yaml --all: a project that fails is an error line and exit 1; the others still run" "$RC:$(printf '%s\n' "$OUT" | grep -c '^ro (.*): error: '):$(printf '%s\n' "$OUT" | grep '^Summary')" "1:1:Summary: 0 created, 0 updated, 5 unchanged, 7 skipped, 1 errors"
yall_list
# exit 2 when the list cannot be read; usage errors write nothing
T2="$(ytree)"; FAKE_LIST_RC=1 yallerr --all; R2="$RC"; check "roles-yaml --all: the list cannot be read -> exit 2 and a message" "$R2:$(printf '%s' "$ERR" | grep -c 'could not read the project list')" "2:1"
printf 'garbage' > "$YA/list.json"; yallrun --all; check "roles-yaml --all: an unexpected answer from orca -> exit 2" "$RC:$OUT" "2:"; yall_list
M=""; for a in "--all --remove" "--all --check" "--all --under $YA/nope" "--all --under" "--under $YA/u" "--dry-run --remove" "--dry-run --check" "--all --mode bogus" "--all --mode"; do
  yallerr $a; M="$M$RC:$([ -z "$OUT" ] && echo silent || echo msg);"
done
check "roles-yaml --all: usage errors exit 1 with a message on stderr only" "$M" "$(for i in 1 2 3 4 5 6 7 8 9; do printf '1:msg;'; done)"
yallrun --all --remove; check "roles-yaml --all --remove: nothing on stdout" "$RC:$OUT" "1:"
check "roles-yaml --all: usage errors and the failed list wrote nothing" "$([ "$(ytree)" = "$T2" ] && echo same || echo diff)" "same"
# the single path: a last stdout line ROLES_YAML_RESULT for each result class; an error leaves only that line on stdout
YS="$TMP/yres"; rm -rf "$YS"; mkdir -p "$YS"; git -C "$YS" init -q; git -C "$YS" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
yres() { (cd "$YS" && PATH="$TMP/yoff:$PATH" "$ROOT/bin/orca-yaml.sh" "$@" 2>/dev/null | tail -n 1); }
M="$(yres)|$(yres)|$(yres --mode pr-reviewer)|$(yres --mode pr-reviewer)|$(yres)"
check "roles-yaml: ROLES_YAML_RESULT created, unchanged, updated, unchanged, updated" "$M" "ROLES_YAML_RESULT=created|ROLES_YAML_RESULT=unchanged|ROLES_YAML_RESULT=updated|ROLES_YAML_RESULT=unchanged|ROLES_YAML_RESULT=updated"
check "roles-yaml --dry-run (single): says what would happen and writes nothing" "$(yres --mode academic-research --dry-run)|$(sed -n 's/^    //p' "$YS/orca.yaml" | tr '\n' ' ')|$(cd "$YS" && PATH="$TMP/yoff:$PATH" "$ROOT/bin/orca-yaml.sh" --dry-run 2>/dev/null | grep -c 'Nothing would change')" "ROLES_YAML_RESULT=updated|\$HOME/.orca-roles/bin/launch.sh |1"
rm -f "$YS/orca.yaml" "$YS/.worktreeinclude"; : > "$YS/.git/info/exclude"; check "roles-yaml --dry-run (single): created, nothing written" "$(yres --dry-run)|$(ls -A "$YS" | tr '\n' ' ')|$(wc -c < "$YS/.git/info/exclude" | tr -d ' ')" "ROLES_YAML_RESULT=created|.git |0"
printf 'scripts:\n  setup: npm i\n' > "$YS/orca.yaml"; check "roles-yaml: ROLES_YAML_RESULT skipped:foreign-orca-yaml" "$(yres)" "ROLES_YAML_RESULT=skipped:foreign-orca-yaml"
git -C "$YS" add -f orca.yaml; git -C "$YS" -c user.name=t -c user.email=t@t commit -q -m yaml; check "roles-yaml: ROLES_YAML_RESULT skipped:committed-orca-yaml" "$(yres)" "ROLES_YAML_RESULT=skipped:committed-orca-yaml"
git -C "$YS" rm -q -f orca.yaml; git -C "$YS" -c user.name=t -c user.email=t@t commit -q -m rm; printf 'keep\n' > "$YS/.worktreeinclude"; git -C "$YS" add -f .worktreeinclude; git -C "$YS" -c user.name=t -c user.email=t@t commit -q -m inc
check "roles-yaml: ROLES_YAML_RESULT skipped:committed-worktreeinclude" "$(yres)" "ROLES_YAML_RESULT=skipped:committed-worktreeinclude"
check "roles-yaml: ROLES_YAML_RESULT skipped:not-a-repo / not-main-checkout and error:invalid-mode" "$(cd "$TMP/ynogit" && GIT_CEILING_DIRECTORIES="$TMP" PATH="$TMP/yoff:$PATH" "$ROOT/bin/orca-yaml.sh" 2>/dev/null | tail -n 1)|$(git init -q --bare "$TMP/ybare" && cd "$TMP/ybare" && PATH="$TMP/yoff:$PATH" "$ROOT/bin/orca-yaml.sh" 2>/dev/null | tail -n 1)|$(yres --mode Bogus)" "ROLES_YAML_RESULT=skipped:not-a-repo|ROLES_YAML_RESULT=skipped:not-main-checkout|ROLES_YAML_RESULT=error:invalid-mode"
yfor local-only "npm i"; M="$(cd "$Y2" && env -u ORCA_CLI_COMMAND PATH="$FB:/usr/bin:/bin" FAKE_LOG="$YLOG" FAKE_PATH="$YP" "$ROOT/bin/orca-yaml.sh" 2>/dev/null | tail -n 1 || true)"
check "roles-yaml: ROLES_YAML_RESULT skipped:local-only-policy" "$M" "ROLES_YAML_RESULT=skipped:local-only-policy"
yfor local-only "$KITL"; check "roles-yaml: ROLES_YAML_RESULT skipped:local-script, exit 0" "$RC:$(printf '%s\n' "$OUT" | tail -n 1)" "0:ROLES_YAML_RESULT=skipped:local-script"
check "roles-yaml --check and --remove print no result line" "$(cd "$YS" && PATH="$TMP/yoff:$PATH" "$ROOT/bin/orca-yaml.sh" --check 2>&1 | grep -c ROLES_YAML_RESULT || true)$(cd "$YS" && PATH="$TMP/yoff:$PATH" "$ROOT/bin/orca-yaml.sh" --remove 2>&1 | grep -c ROLES_YAML_RESULT || true)" "00"
# the old mode id (academic-writer) is an alias of academic-research in roles-yaml (single project, --all, --dry-run); --check and --remove stay as they were
YN="$TMP/yalias"; rm -rf "$YN"; mkdir -p "$YN/bin" "$YN/show"; cp "$YA/bin/orca" "$YN/bin/orca"
for n in k1 k2 k3 fo tr one; do mkdir -p "$YN/$n"; git -C "$YN/$n" init -q; git -C "$YN/$n" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; done
ynsingle() { (cd "$YN/$1" && shift && PATH="$YN/bin:$PATH" FAKE_LIST="$YN/list.json" FAKE_SHOW="$YN/show" "$ROOT/bin/orca-yaml.sh" "$@" 2>"$YN/err" || true); }
ynall() { try env PATH="$YN/bin:$PATH" FAKE_LIST="$YN/list.json" FAKE_SHOW="$YN/show" "$ROOT/bin/orca-yaml.sh" "$@" 2>"$YN/err"; }
ynold() { sed 's/--mode academic-research/--mode academic-writer/' "$YN/$1/orca.yaml" > "$YN/t.yaml"; cat "$YN/t.yaml" > "$YN/$1/orca.yaml"; }
ynmode() { sed -n 's/^.*launch\.sh//p' "$YN/$1/orca.yaml" | tr -d ' '; }
ynhash() { (cd "$YN" && find . -type f -not -path './bin/*' -not -path './show/*' -not -name err -not -name t.yaml -not -name list.json | LC_ALL=C sort | xargs shasum) | shasum; }
jq -nc --arg d "$YN" '{ok:true,result:{repos:(["k1","k2","k3","fo","tr"] | map({displayName:., path:($d + "/" + .), kind:"git"}))}}' > "$YN/list.json"
NOTE_AW="Note: mode 'academic-writer' is now called 'academic-research'; the old name works until the next version. Found in: --mode. Update it to academic-research."
# single project: --mode academic-writer writes the new id, one note, same result line; --dry-run writes nothing
OUT1="$(ynsingle one --mode academic-writer)"; E1="$(cat "$YN/err")"
check "roles-yaml alias: --mode academic-writer writes academic-research and prints one note on stderr; the result line is the one of the new id" "$(printf '%s' "$OUT1" | tail -n 1):$(ynmode one):$(printf '%s\n' "$E1" | grep -c '^Note:'):$([ "$E1" = "$NOTE_AW" ] && echo exact)" "ROLES_YAML_RESULT=created:--modeacademic-research:1:exact"
rm -f "$YN/one/orca.yaml" "$YN/one/.worktreeinclude"; : > "$YN/one/.git/info/exclude"; H0="$(ynhash)"
OLDD="$(ynsingle one --mode academic-writer --dry-run)"; NEWD="$(ynsingle one --mode academic-research --dry-run)"
check "roles-yaml alias: --mode academic-writer --dry-run prints what the new id prints and writes nothing" "$([ "$OLDD" = "$NEWD" ] && echo same):$([ "$(ynhash)" = "$H0" ] && echo unchanged):$(ls -A "$YN/one" | tr '\n' ' ')" "same:unchanged:.git "
# --all: kit orca.yaml files with the old id are renamed (dry run: announced only); the repair path, a tracked file and someone else's file
for n in k1 k2 k3; do ynsingle "$n" --mode academic-research >/dev/null; ynold "$n"; done
rm -f "$YN/k2/.worktreeinclude"; printf 'scripts:\n  setup: echo academic-writer\n' > "$YN/fo/orca.yaml"
ynsingle tr --mode academic-research >/dev/null; ynold tr; git -C "$YN/tr" add -f orca.yaml; git -C "$YN/tr" -c user.name=t -c user.email=t@t commit -q -m yaml
printf '{"ok":true,"result":{"repo":{"hookSettings":{"commandSourcePolicy":"local-only","scripts":{"setup":"npm i"}}}}}' > "$YN/show/k3"
H1="$(ynhash)"; ynall --all --dry-run; DR="$RC:$(printf '%s\n' "$OUT" | grep -c '^k[123] (.*): would update (mode renamed to academic-research)$'):$(printf '%s\n' "$OUT" | grep '^Summary'):$(grep -c '^Note:' "$YN/err" || true):$([ "$(ynhash)" = "$H1" ] && echo unchanged || echo CHANGED)"
ynall --all; AL="$RC:$(printf '%s\n' "$OUT" | grep -c '^k[12] (.*): updated (mode renamed to academic-research)$'):$(printf '%s\n' "$OUT" | grep -c '^k3 (.*): skipped: local-only-policy$'):$(printf '%s\n' "$OUT" | grep '^Summary'):$(ynmode k1)/$(ynmode k2)/$(ynmode k3):$(grep -cx orca.yaml "$YN/k2/.worktreeinclude"):$(ynmode tr):$(tr -d ' \n' < "$YN/fo/orca.yaml")"
check "roles-yaml alias: --all --dry-run announces the rename of the kit's old lines and writes nothing; --all renames them (repairing k2) and reports a child that skips (local-only policy) as skipped; a tracked kit file and someone else's file are not touched" "$DR|$AL" "0:3:Summary: 0 created, 3 updated, 0 unchanged, 2 skipped, 0 errors:0:unchanged|0:2:1:Summary: 0 created, 2 updated, 0 unchanged, 3 skipped, 0 errors:--modeacademic-research/--modeacademic-research/--modeacademic-writer:1:--modeacademic-writer:scripts:setup:echoacademic-writer"
# --all --mode academic-writer: one note, every project gets the new id; --check and --remove print what they printed and need no mode
ynold k1; ynold k2; H2="$(ynhash)"; ynall --all --mode academic-writer --dry-run; D2="$RC:$(grep -c '^Note:' "$YN/err" || true):$(printf '%s\n' "$OUT" | grep -c 'would update to mode academic-research'):$([ "$(ynhash)" = "$H2" ] && echo unchanged || echo CHANGED)"
ynall --all --mode academic-writer; A2="$RC:$(grep -c '^Note:' "$YN/err" || true):$(printf '%s\n' "$OUT" | grep -c ': updated to mode academic-research$'):$(ynmode k1)/$(ynmode k2)"
check "roles-yaml alias: --all --mode academic-writer (also --dry-run) prints the note once and writes the new id in every project" "$D2|$A2" "0:1:2:unchanged|0:1:2:--modeacademic-research/--modeacademic-research"
ynold k1; CK1="$(ynsingle k1 --check)"; CKE="$(cat "$YN/err")"; ynsingle k1 --mode academic-research >/dev/null; CK2="$(ynsingle k1 --check)"; ynsingle k1 --remove >/dev/null; RME="$(cat "$YN/err")"
check "roles-yaml alias: --check prints the same with the old line as with the new one and no note, --remove no note and removes the file" "$([ "$CK1" = "$CK2" ] && echo same):$CKE:$RME:$([ -e "$YN/k1/orca.yaml" ] && echo left)" "same:::"
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

# the options add to the saved ones (library level)
S0='{"only":["a"],"enable":["x","y"],"disable":["z","w"],"set":[{"path":["roles","dev","model"],"value":"a"},{"path":["k"],"value":1}],"mode":"programmer"}'
mo() { printf '%s' "$S0" > "$TMP/mo.saved"; printf '%s' "$1" > "$TMP/mo.new"; merge_overrides "$TMP/mo.saved" "$TMP/mo.new" ${2:+"$2"}; }
E0='"only":[],"enable":[],"disable":[],"set":[]'
check "merge_overrides: nothing new keeps the saved ones" "$(mo "{$E0}")" "$S0"
check "merge_overrides: a new --only replaces the saved one" "$(mo '{"only":["b","c"],"enable":[],"disable":[],"set":[]}' | jq -c .only)" '["b","c"]'
check "merge_overrides: enable/disable add up, the newest wins per role, no duplicates" "$(mo '{"only":[],"enable":["z","y","v"],"disable":["x","w"],"set":[]}' | jq -c '[.enable,.disable]')" '[["y","z","v"],["w","x"]]'
check "merge_overrides: the same --set path takes the new value, other saved sets stay" "$(mo '{"only":[],"enable":[],"disable":[],"set":[{"path":["roles","dev","model"],"value":"b"}]}' | jq -c .set)" '[{"path":["k"],"value":1},{"path":["roles","dev","model"],"value":"b"}]'
check "merge_overrides: the new mode wins, the saved mode stays otherwise" "$(mo '{"only":[],"enable":[],"disable":[],"set":[],"mode":"pr-reviewer"}' | jq -r .mode):$(mo "{$E0}" | jq -r .mode)" "pr-reviewer:programmer"
check "merge_overrides: a different mode drops the saved selections and keeps the sets" "$(mo '{"only":[],"enable":["q"],"disable":[],"set":[],"mode":"pr-reviewer"}')" '{"only":[],"enable":["q"],"disable":[],"set":[{"path":["roles","dev","model"],"value":"a"},{"path":["k"],"value":1}],"mode":"pr-reviewer"}'
check "merge_overrides: the same mode, or a saved one with none (programmer), keeps them" "$(mo '{"only":[],"enable":[],"disable":[],"set":[],"mode":"programmer"}' | jq -c .enable):$(S0="$(printf '%s' "$S0" | jq -c 'del(.mode)')" mo '{"only":[],"enable":[],"disable":[],"set":[],"mode":"programmer"}' | jq -c .enable)" '["x","y"]:["x","y"]'
check "merge_overrides: the third argument (previous effective mode) is what the new mode is compared with" "$(mo '{"only":[],"enable":["q"],"disable":[],"set":[],"mode":"programmer"}' pr-reviewer | jq -c .enable):$(mo '{"only":[],"enable":[],"disable":[],"set":[],"mode":"programmer"}' programmer | jq -c .enable)" '["q"]:["x","y"]'
# launch.sh end to end: own kit with a second mode
pk_setup
mkdir -p "$PK/prompts/pr-reviewer"; for f in planner common-workers rv; do echo "# $f" > "$PK/prompts/pr-reviewer/$f.md"; done
cat > "$PK/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner", "modes": "all" }, "dev": { "title": "Dev" }, "tester": { "title": "Tester", "enabled": false },
             "deployer": { "title": "Deployer" }, "rv": { "title": "Rv", "modes": ["pr-reviewer"] } } }
J
OW="$TMP/oproj"; mkdir -p "$OW" "$TMP/obin"; git -C "$OW" init -q; OG="$OW/.git"
cat > "$TMP/obin/orca" <<'EOS'
#!/bin/sh
case "$1 $2" in
  "terminal create") while [ $# -gt 0 ]; do [ "$1" = --title ] && t="$2"; shift; done; echo "{\"handle\":\"h-$t\"}";;
  "terminal show") echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
esac
exit 0
EOS
chmod +x "$TMP/obin/orca"; printf '#!/bin/sh\nexit 0\n' > "$TMP/obin/kickoff"; chmod +x "$TMP/obin/kickoff"
ol() { rm -f "$OG/orca-roles.env"; (cd "$OW" && HOME="$PH" PATH="$TMP/obin:$PATH" ORCA_ROLES_KICKOFF="$TMP/obin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PKL/bin/launch.sh" "$@" 2>&1); }
osaved() { jq -c "$1" "$OG/orca-roles.overrides.json"; }
oteam() { cut -d= -f1 "$OG/orca-roles.env" | tr '\n' ' '; }
try ol --only dev; try ol --set roles.dev.model=a
check "launch: a saved --only is kept when a later run passes only --set" "$RC:$(oteam):$(osaved '[.only,.set]')" '0:PLANNER DEV :[["dev"],[{"path":["roles","dev","model"],"value":"a"}]]'
try ol --reset --disable deployer; try ol --enable deployer
check "launch: --disable x then --enable x leaves x enabled and not disabled" "$RC:$(oteam):$(osaved '[.enable,.disable]')" '0:PLANNER DEV DEPLOYER :[["deployer"],[]]'
try ol --reset --set settings.jiraHandoff=false --set roles.dev.model=a; try ol --set roles.dev.model=b
check "launch: the same --set path takes the new value and the other saved sets stay" "$RC:$(osaved '.set')" '0:[{"path":["settings","jiraHandoff"],"value":false},{"path":["roles","dev","model"],"value":"b"}]'
check "launch: the merged value reaches the effective config" "$(jq -r '.roles.dev.model' "$OG/orca-roles.config.json")" "b"
try ol --only dev; try ol --only deployer
check "launch: a new --only replaces the saved one" "$RC:$(oteam):$(osaved .only)" '0:PLANNER DEPLOYER :["deployer"]'
try ol --reset --set roles.dev.model=c
check "launch: --reset then options keeps only the new ones" "$RC:$(oteam):$(osaved '[.only,.enable,.disable,.set]')" '0:PLANNER DEV DEPLOYER :[[],[],[],[{"path":["roles","dev","model"],"value":"c"}]]'
try ol --reset --mode pr-reviewer; try ol --set roles.rv.model=m
check "launch: the saved mode is kept when later options omit it" "$RC:$(osaved .mode):$(jq -r .settings.mode "$OG/orca-roles.config.json")" "0:\"pr-reviewer\":pr-reviewer"
try ol --reset --enable dev; B="$(cat "$OG/orca-roles.overrides.json" "$OG/orca-roles.config.json" | cksum)"
try ol --mode pr-reviewer --enable dev
check "launch: a result that conflicts with the mode fails and saves nothing" "$RC:$(cat "$OG/orca-roles.overrides.json" "$OG/orca-roles.config.json" | cksum):$(printf '%s' "$OUT" | grep -c 'ERROR: role dev is not part of mode pr-reviewer')" "1:$B:1"
}

sec_launch() {
write_launch_config
# launch.sh end to end with a fake 'orca' (each tab is called h-<title>; none is alive when relaunching)
L="$TMP/lproj"; mkdir -p "$L" "$TMP/lbin"; git -C "$L" init -q
cat > "$TMP/lbin/orca" <<'EOS'
#!/bin/sh
case "$1 $2" in
  "terminal create") while [ $# -gt 0 ]; do [ "$1" = --title ] && t="$2"; shift; done; echo "{\"handle\":\"h-$t\"}";;
  "terminal show") echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
esac
exit 0
EOS
chmod +x "$TMP/lbin/orca"
launch() { (cd "$L" && HOME="$TMP/home" PATH="$TMP/lbin:$PATH" "$TMP/home/.orca-roles/bin/launch.sh" "$@" 2>&1); }
launch_from() { local d="$1"; shift; (cd "$d" && HOME="$TMP/home" PATH="$TMP/lbin:$PATH" "$TMP/home/.orca-roles/bin/launch.sh" "$@" 2>&1); }
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
try launch --only dev; X1="$(grep -cxF '/qa-e2e/' "$L/.git/info/exclude"):$(grep -cxF 'qa-evidence/' "$L/.git/info/exclude"):$(printf '%s\n' "$OUT" | grep -c 'tracked by git' || true)"
mkdir -p "$L/qa-e2e/f" "$L/sub/qa-e2e"; touch "$L/qa-e2e/f/a.flow.ts" "$L/sub/qa-e2e/b.flow.ts"
X2="$(git -C "$L" check-ignore -q qa-e2e/f/a.flow.ts && echo y || echo n)$(git -C "$L" check-ignore -q sub/qa-e2e/b.flow.ts && echo y || echo n):$(git -C "$L" status --porcelain | grep -c 'qa-e2e/f' || true)"
check "launch: the anchored /qa-e2e/ goes once into info/exclude (not a second time on relaunch), qa-e2e at the root is ignored and a nested qa-e2e is not, no warning when nothing is tracked" "$X1:$X2" "1:1:0:yn:0"
git -C "$L" add -f qa-e2e/f/a.flow.ts; try launch --only dev
check "launch: a tracked file under qa-e2e/ -> a warning naming the folder, launch still succeeds" "$RC:$(printf '%s\n' "$OUT" | grep -c 'Warning: files under qa-e2e/ are tracked by git'):$(handles):$(grep -cxF '/qa-e2e/' "$L/.git/info/exclude")" "0:1:PLANNER DEV :1"
mkdir -p "$L/sub/deep"; try launch_from "$L/sub/deep" --only dev; Y1="$RC:$(printf '%s\n' "$OUT" | grep -c 'Warning: files under qa-e2e/ are tracked by git')"
git -C "$L" rm -q --cached qa-e2e/f/a.flow.ts; try launch_from "$L/sub/deep" --only dev; Y2="$RC:$(printf '%s\n' "$OUT" | grep -c 'tracked by git' || true)"
check "launch: the tracked-qa-e2e warning also fires when launched from a subdirectory, and not once nothing is tracked" "$Y1|$Y2" "0:1|0:0"
rm -rf "$L/qa-e2e" "$L/sub"
try launch --enable nobody; check "launch: unknown role fails" "$RC" "1"
check "launch: an error does not overwrite the saved exceptions" "$(jq -c .only "$L/.git/orca-roles.overrides.json")" '["dev"]'
# launch.sh warns when new worktrees would not start the kit, and a failing check never changes its outcome
mkdir -p "$TMP/lbin2"; cat > "$TMP/lbin2/orca" <<'EOS'
#!/bin/sh
case "$1 $2" in
  "terminal create") while [ $# -gt 0 ]; do [ "$1" = --title ] && t="$2"; shift; done; echo "{\"handle\":\"h-$t\"}";;
  "terminal show") [ -n "$FAKE_SHOW" ] && echo "$FAKE_SHOW" && exit 0; echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
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

# unknown results, lock and worktree id (own fake orca: each handle's answer is a file in $LK)
LK="$TMP/lk"; mkdir -p "$LK/bin" "$LK/proj"; git -C "$LK/proj" init -q; LKG="$LK/proj/.git"; LKL="$LK/orca.log"; : > "$LKL"
cat > "$LK/bin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$LKL"
case "\$1 \$2" in
  "terminal create") while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; [ -f "$LK/failcreate-\$t" ] && exit 1; echo "{\"handle\":\"h-\$t\"}";;
  "terminal list") [ -f "$LK/listfail" ] && exit 1; echo '{"terminals":[]}';;
  "terminal show") case "\$4" in
    h-*) echo "{\"result\":{\"terminal\":{\"ptyId\":\"pty-\$4\",\"agentIdentity\":\"claude\"}}}";;
    *) m="\$(cat "$LK/show.\$4" 2>/dev/null)"; case "\$m" in
      alive) echo '{"result":{"terminal":{"agentIdentity":"claude"}}}';;
      rt) echo '{"ok":false,"error":{"code":"runtime_unavailable"}}'; exit 1;;
      *) echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;; esac;; esac;;
esac
exit 0
EOS
chmod +x "$LK/bin/orca"; printf '#!/bin/sh\nexit 0\n' > "$LK/bin/kickoff"; chmod +x "$LK/bin/kickoff"
lkl() { (cd "$LK/proj" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE -u ORCA_WORKTREE_ID HOME="$TMP/home" PATH="$LK/bin:$PATH" ORCA_ROLES_KICKOFF="${LKK:-$LK/bin/kickoff}" ORCA_ROLES_AGENT_CHECKS=1 "$TMP/home/.orca-roles/bin/launch.sh" "$@" 2>&1); }
lkdrain() { local n=0; while pgrep -f "$LK/bin/kickoff2" >/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done; [ "$n" -lt 100 ] || { echo "FAIL launch: a stub kickoff was still running after 10s"; FAIL=1; }; }   # a kickoff left from the previous check must be gone before the fixture is reset
lkreset() { lkdrain; rm -rf "$LKG"/orca-roles.* "$LK"/show.* "$LK"/listfail "$LK"/failcreate-* || { echo "FAIL launch: could not reset the fixture"; FAIL=1; }; : > "$LKL"; }
lkreg() { local pid="$1"; shift; { mkdir -p "$LKG/orca-roles.kickoff.d" && printf '%s\n' "$*" > "$LKG/orca-roles.kickoff.d/$pid"; } 2>/dev/null || { echo "FAIL launch: could not register the stub kickoff $pid in $LKG/orca-roles.kickoff.d"; FAIL=1; }; }
lkcnt() { grep -cE "^terminal $1" "$LKL" || true; }
lksum() { cat "$LKG/orca-roles.env" "$LKG/orca-roles.pty" 2>/dev/null | cksum; }
lkseed() { printf 'PLANNER=p1\nDEV=d1\nDEPLOYER=x1\n' > "$LKG/orca-roles.env"; printf 'PLANNER=pty1\nDEV=pty2\nDEPLOYER=pty3\n' > "$LKG/orca-roles.pty"; cp "$KIT/config.json" "$LKG/orca-roles.config.json"; }
# role 2 unknown: the stale role 1 is not reopened either; nothing is closed or opened and the state is byte-identical
lkreset; lkseed; echo alive > "$LK/show.x1"; echo rt > "$LK/show.d1"; B="$(lksum)"
try lkl; R1="$RC:$(printf '%s' "$OUT" | grep -c 'ERROR: Orca is not ready (runtime_unavailable) for Dev: no tab was closed or opened'):$(lkcnt create):$(lkcnt close):$(lksum)"
try lkl --status
check "launch: a role with an unknown tab state stops the launch before any close or create, state byte-identical; --status prints 'unknown (<code>)', exits 0" "$R1:$RC:$(printf '%s' "$OUT" | grep -c '^Dev	d1	unknown (runtime_unavailable)	'):$(lkcnt create):$(lkcnt close)" "1:1:0:0:$B:0:1:0:0"
# LISTOK: a saved handle that Orca calls stale cannot be told from a restored tab when the list failed
lkreset; lkseed; echo alive > "$LK/show.p1"; echo alive > "$LK/show.x1"; : > "$LK/listfail"; B="$(lksum)"
try lkl; check "launch: terminal list failed and a role with a saved handle has no tab: stop, nothing closed or opened, state byte-identical" "$RC:$(printf '%s' "$OUT" | grep -c "ERROR: 'orca terminal list' failed: cannot tell whether Dev's tab was restored"):$(lkcnt create):$(lkcnt close):$(lksum)" "1:1:0:0:$B"
lkreset; : > "$LK/listfail"; try lkl; R1="$RC:$(lkcnt create):$(cut -d= -f1 "$LKG/orca-roles.env" 2>/dev/null | tr '\n' ' ' || true)"
lkreset; printf 'PLANNER=p1\n' > "$LKG/orca-roles.env"; cp "$KIT/config.json" "$LKG/orca-roles.config.json"; echo alive > "$LK/show.p1"; : > "$LK/listfail"; try lkl
check "launch: terminal list failed proceeds on a first launch and for a newly enabled role without a saved handle" "$R1:$RC:$(lkcnt create):$(cut -d= -f1 "$LKG/orca-roles.env" 2>/dev/null | tr '\n' ' ' || true)" "0:3:PLANNER DEV DEPLOYER :0:2:PLANNER DEV DEPLOYER "
# interrupted launch: the tabs opened so far stay in the state files
lkreset; : > "$LK/failcreate-Dev"; try lkl
check "launch: an interrupted launch keeps the tab it opened in orca-roles.env and .pty" "$RC:$(cat "$LKG/orca-roles.env" 2>/dev/null | tr '\n' ' '):$(cat "$LKG/orca-roles.pty" 2>/dev/null | tr '\n' ' ')" "1:PLANNER=h-Planner :PLANNER=pty-h-Planner "
# H1: a tab opened by an interrupted launch gets its role message on the rerun and is not opened again
printf '#!/bin/sh\necho "$4|$7" >> "%s"\ncp "$2" "$(dirname "$2")/orca-roles.kicked"\n' "$LK/kick.log" > "$LK/bin/kickoff2"; chmod +x "$LK/bin/kickoff2"
lkreset; : > "$LK/kick.log"; : > "$LK/failcreate-Dev"; try lkl; R1="$RC:$(cat "$LKG/orca-roles.kicked" 2>/dev/null | wc -c | tr -d ' '):$(wc -l < "$LK/kick.log" | tr -d ' ')"
rm -f "$LK/failcreate-Dev"; : > "$LKL"; LKK="$LK/bin/kickoff2" try lkl; lkdrain
R2="$RC:$(lkcnt create):$(grep -c '^The tab of Planner (h-Planner) never got its role message; sending it now.$' <<<"$OUT" || true):$(tr '\n' ' ' < "$LK/kick.log"):$(cut -d= -f1 "$LKG/orca-roles.kicked" 2>/dev/null | tr '\n' ' ' || true)"
: > "$LKL"; : > "$LK/kick.log"; LKK="$LK/bin/kickoff2" try lkl; lkdrain
check "launch: an interrupted launch, then a rerun: the tab opened in run 1 is kicked (reused), not opened again; a further rerun does nothing" "$R1:$R2:$RC:$(lkcnt create):$(wc -c < "$LK/kick.log" | tr -d ' '):$(printf '%s' "$OUT" | grep -c 'All roles are already open')" "1:0:0:0:2:1: planner dev deployer| planner :PLANNER DEV DEPLOYER :0:0:0:1"
# upgrade from an older kit: no marker file and a saved team: every alive tab counts as kicked
lkreset; lkseed; for h in p1 d1 x1; do echo alive > "$LK/show.$h"; done; : > "$LK/kick.log"; LKK="$LK/bin/kickoff2" try lkl; lkdrain
check "launch: no orca-roles.kicked and an existing team (older kit): nothing is kicked or opened, the marker is seeded from orca-roles.env" "$RC:$(lkcnt create):$(wc -c < "$LK/kick.log" | tr -d ' '):$(printf '%s' "$OUT" | grep -c 'never got its role message'):$(cmp -s "$LKG/orca-roles.env" "$LKG/orca-roles.kicked" && echo same || echo differ)" "0:0:0:0:same"
# an alive tab whose marker holds another handle is kicked again, the others are not
printf 'PLANNER=p1\nDEV=old\nDEPLOYER=x1\n' > "$LKG/orca-roles.kicked"; : > "$LK/kick.log"; LKK="$LK/bin/kickoff2" try lkl; lkdrain
check "launch: an alive tab whose marker has another handle is kicked as reused, the other alive tabs are left alone" "$RC:$(lkcnt create):$(tr '\n' ' ' < "$LK/kick.log"):$(grep -c '^DEV=d1$' "$LKG/orca-roles.kicked")" "0:0: dev| dev :1"
# a running kickoff of a previous launch will reach the unmarked alive tab: it is not kicked again
lkkick() { lkreset; lkseed; for h in p1 d1 x1; do echo alive > "$LK/show.$h"; done; printf 'PLANNER=p1\nDEV=old\nDEPLOYER=x1\n' > "$LKG/orca-roles.kicked"; : > "$LK/kick.log"; mkdir -p "$LKG/orca-roles.kickoff.d" || { echo "FAIL launch: could not create the kickoff registry"; FAIL=1; }; }
lkkick; sleep 30 & KP=$!; lkreg "$KP" "dev deployer"; LKK="$LK/bin/kickoff2" try lkl; lkdrain
check "launch: a live kickoff listing the unmarked alive role: no re-kick, the line is printed, nothing opened, its file is kept" "$RC:$(lkcnt create):$(wc -c < "$LK/kick.log" | tr -d ' '):$(printf '%s' "$OUT" | grep -c "^The kickoff of the previous launch is still running (pid $KP): Dev gets its role from it.$"):$(printf '%s' "$OUT" | grep -c 'never got its role message'):$(printf '%s' "$OUT" | grep -c 'All roles are already open'):$([ -f "$LKG/orca-roles.kickoff.d/$KP" ] && echo kept || echo gone)" "0:0:0:1:0:1:kept"
# a live kickoff that does not list the role: the role is kicked as before
lkreg "$KP" "planner"; : > "$LK/kick.log"; LKK="$LK/bin/kickoff2" try lkl; lkdrain
check "launch: a live kickoff that does not list the unmarked role: it is kicked as reused" "$RC:$(lkcnt create):$(tr '\n' ' ' < "$LK/kick.log"):$(printf '%s' "$OUT" | grep -c 'The kickoff of the previous launch is still running'):$(printf '%s' "$OUT" | grep -c '^The tab of Dev (d1) never got its role message; sending it now.$')" "0:0: dev| dev :0:1"
# a role name that only contains the listed one as a substring is not listed
lkkick; lkreg "$KP" "devx xdev"; LKK="$LK/bin/kickoff2" try lkl; lkdrain
check "launch: a live kickoff listing only roles that merely contain the role's name does not count" "$RC:$(tr '\n' ' ' < "$LK/kick.log")" "0: dev| dev "
# a dead pid: its file is removed and the role is kicked as before; a live one is left alone
kill "$KP" 2>/dev/null; wait "$KP" 2>/dev/null || true
lkkick; sleep 30 & KP2=$!; lkreg "$KP" "dev"; lkreg "$KP2" "dev"; kill "$KP2"; wait "$KP2" 2>/dev/null || true
sleep 30 & KP3=$!; lkreg "$KP3" "planner"
LKK="$LK/bin/kickoff2" try lkl; lkdrain
check "launch: files of dead pids are removed, a live kickoff's file is kept, and the role of a dead kickoff is kicked" "$RC:$(tr '\n' ' ' < "$LK/kick.log"):$([ -f "$LKG/orca-roles.kickoff.d/$KP" ] && echo kept || echo gone):$([ -f "$LKG/orca-roles.kickoff.d/$KP2" ] && echo kept || echo gone):$([ -f "$LKG/orca-roles.kickoff.d/$KP3" ] && echo kept || echo gone)" "0: dev| dev :gone:gone:kept"
kill "$KP3" 2>/dev/null; wait "$KP3" 2>/dev/null || true
# a launch that starts a kickoff registers it under the kickoff's pid with the roles it kicks
printf '#!/bin/sh\nexec sleep 5\n' > "$LK/bin/kickoff3"; chmod +x "$LK/bin/kickoff3"
lkreset; LKK="$LK/bin/kickoff3" try lkl
RF="$(ls "$LKG/orca-roles.kickoff.d" 2>/dev/null | head -1)"
check "launch: a started kickoff is registered by its pid with the roles it will kick" "$RC:$(ls "$LKG/orca-roles.kickoff.d" | wc -l | tr -d ' '):$(cat "$LKG/orca-roles.kickoff.d/$RF" 2>/dev/null):$(kill -0 "$RF" 2>/dev/null && echo alive || echo dead)" "0:1:planner dev deployer:alive"
kill "$RF" 2>/dev/null || true
# lock
lkreset; mkdir "$LKG/orca-roles.lock"; sleep 30 & HP=$!; echo "$HP" > "$LKG/orca-roles.lock/pid"
ORCA_ROLES_LOCK_WAIT=2 try lkl
check "launch: a lock held by a live pid waits, then stops with nothing changed and the lock left to its owner" "$RC:$(printf '%s' "$OUT" | grep -c "^Another roles is running in this worktree (pid $HP); waiting...$"):$(printf '%s' "$OUT" | grep -c "^ERROR: another roles is still running in this worktree (pid $HP). Nothing was changed."):$(lkcnt create):$([ -e "$LKG/orca-roles.env" ] && echo 1 || echo 0):$(cat "$LKG/orca-roles.lock/pid")" "1:1:1:0:0:$HP"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null || true
sleep 0 & DP=$!; wait "$DP"; echo "$DP" > "$LKG/orca-roles.lock/pid"
try lkl; R1="$RC:$(printf '%s' "$OUT" | grep -c "^Took over a stale lock (pid $DP is gone).$"):$(lkcnt create):$([ -e "$LKG/orca-roles.lock" ] && echo held || echo free)"
lkreset; mkdir "$LKG/orca-roles.lock"; ORCA_ROLES_LOCK_WAIT=1 try lkl
check "launch: a lock whose pid is dead is taken over; one without a pid file is waited for, then taken over; both run and remove the lock" "$R1:$RC:$(lkcnt create):$([ -e "$LKG/orca-roles.lock" ] && echo held || echo free)" "0:1:3:free:0:3:free"
# a launch blocked by the lock reads the state the first one wrote: every role alive, nothing opened
lkreset; mkdir "$LKG/orca-roles.lock"; sleep 30 & HP=$!; echo "$HP" > "$LKG/orca-roles.lock/pid"
(cd "$LK" && sleep 2; lkseed; for h in p1 d1 x1; do echo alive > "$LK/show.$h"; done; kill "$HP"; rm -rf "$LKG/orca-roles.lock") &
ORCA_ROLES_LOCK_WAIT=20 try lkl; wait
check "launch: blocked by the lock, it reads the state written meanwhile and opens nothing when every role is alive" "$RC:$(printf '%s' "$OUT" | grep -c 'All roles are already open'):$(lkcnt create):$(lkcnt close)" "0:1:0:0"
# worktree id
lkreset
try lkl id:AAA; R1="$RC:$(printf '%s' "$OUT" | grep -c '^Warning: this folder was launched before' || true)"
try lkl id:AAA; R2="$(printf '%s' "$OUT" | grep -c '^Warning: this folder was launched before' || true)"
try lkl id:BBB; R3="$RC:$(printf '%s' "$OUT" | grep -c '^Warning: this folder was launched before as worktree id:AAA and now as id:BBB; if Orca lists it twice, its tabs may be duplicated.$'):$(cat "$LKG/orca-roles.wtid")"
try lkl active; R4="$(printf '%s' "$OUT" | grep -c '^Warning: this folder was launched before' || true):$(cat "$LKG/orca-roles.wtid")"
check "launch: a changed worktree id warns (and is saved), the same id or 'active' does not" "$R1:$R2:$R3:$R4" "0:0:0:0:1:id:BBB:0:id:BBB"
lkreset
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
    *) echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;; esac;;
esac
exit 0
EOS
chmod +x "$TMP/sbin/orca"
status() { (cd "$S" && HOME="$TMP/home" PATH="$TMP/sbin:$PATH" ORCA_ROLES_AGENT_CHECKS=1 "$TMP/home/.orca-roles/bin/launch.sh" "$@" 2>&1); }
try status --status; check "status: no state" "$RC:$(printf '%s' "$OUT" | tr '\n' '/')" "0:Kit: unknown (unknown)/No team launched in this worktree."
: > "$G/orca-roles.env"; try status --status; check "status: empty state" "$RC:$(printf '%s' "$OUT" | tr '\n' '/')" "0:Kit: unknown (unknown)/No team launched in this worktree."
jq '.settings.mode = "programmer"' "$KIT/config.json" > "$G/orca-roles.config.json"
jq '.roles.dev.model = "m-dev"' "$G/orca-roles.config.json" > "$G/c.tmp" && mv "$G/c.tmp" "$G/orca-roles.config.json"
printf 'PLANNER=h-up\nDEV=h-none\nDEPLOYER=h-gone\n' > "$G/orca-roles.env"
printf 'XDEV=m-x\nPLANNER=m-ok\nDEPLOYER=FAILED:m-bad\n' > "$G/orca-roles.models"
printf 'PLANNER=pty-1\n' > "$G/orca-roles.pty"; printf '{"only":["dev"],"enable":[],"disable":[],"set":[]}' > "$G/orca-roles.overrides.json"
ssum() { cat "$G/orca-roles.config.json" "$G/orca-roles.overrides.json" "$G/orca-roles.env" "$G/orca-roles.pty" "$G/orca-roles.models" | cksum; ls "$G" | cksum; }
S0="$(ssum)"; : > "$SLOG"
try status --status
check "status: report" "$RC:$(printf '%s' "$OUT" | tr '\t\n' '|/')" "0:Kit: unknown (unknown)/Mode: programmer/Planner|h-up|alive|-|m-ok|-|-/Dev|h-none|no tab|m-dev|-|-|-/Deployer|h-gone|agent gone|-|FAILED:m-bad|-|-"
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
    *) echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;; esac;;
esac
exit 0
EOS
jq '.roles.dev.agent = "custom" | .roles.dev.command = "c" | .settings.mode = "programmer"' "$G/orca-roles.config.json" > "$G/c.tmp" && mv "$G/c.tmp" "$G/orca-roles.config.json"
printf 'PLANNER=h-orph\nDEV=h-cust\nGHOST=h-cust\n' > "$G/orca-roles.env"; rm -f "$G/orca-roles.models"; S0="$(ssum 2>/dev/null)"
try status --status
check "status: orphaned, custom agent alive, role missing from the config (checked like claude)" "$RC:$(printf '%s' "$OUT" | tr '\t\n' '|/')" "0:Kit: unknown (unknown)/Mode: programmer/Planner|h-orph|orphaned|-|-|-|-/Dev|h-cust|alive|m-dev|-|-|-/ghost|h-cust|agent gone|-|-|-|-"
mv "$G/orca-roles.config.json" "$G/cfg.saved"
printf '{"roles":{"dev":{"title":"Developer","model":"m-proj"}},"settings":{"mode":"programmer"}}' > "$S/.orca-roles.json"
printf 'DEV=h-none\n' > "$G/orca-roles.env"
try status --status
check "status: without a saved config uses the merged one" "$RC:$(printf '%s' "$OUT" | tr '\t\n' '|/')" "0:Kit: unknown (unknown)/Mode: programmer/Developer|h-none|no tab|m-proj|-|-|-"
check "status: no saved config is not created" "$([ -e "$G/orca-roles.config.json" ] && echo created || echo absent):$([ -e "$G/orca-roles-launch.log" ] && echo log || echo nolog)" "absent:nolog"
# no saved config: the project's mode, a saved --mode, no jq error with an answering tab, nothing written, temp file gone
mkdir -p "$TMP/stmp"; printf 'DEV=h-cust\n' > "$G/orca-roles.env"
printf '{"settings":{"mode":"pr-reviewer"}}' > "$S/.orca-roles.json"; S0="$(ssum 2>/dev/null)"
OUT="$(cd "$S" && HOME="$TMP/home" PATH="$TMP/sbin:$PATH" TMPDIR="$TMP/stmp" ORCA_ROLES_AGENT_CHECKS=1 "$TMP/home/.orca-roles/bin/launch.sh" --status 2>"$TMP/status.err")"
check "status: no saved config, the project's mode" "$(printf '%s' "$OUT" | sed -n 2p)" "Mode: pr-reviewer"
check "status: no saved config, an answering tab prints no jq error" "$(grep -c 'jq: error' "$TMP/status.err")" "0"
check "status: no saved config writes nothing and removes its temp file" "$([ "$(ssum 2>/dev/null)" = "$S0" ] && echo unchanged || echo CHANGED):$(ls "$TMP/stmp" | wc -l | tr -d ' ')" "unchanged:0"
rm -f "$S/.orca-roles.json"
printf '{"only":[],"enable":[],"disable":[],"set":[],"mode":"pr-reviewer"}' > "$G/orca-roles.overrides.json"
try status --status; check "status: no saved config, a saved --mode" "$RC:$(printf '%s' "$OUT" | sed -n 2p)" "0:Mode: pr-reviewer"
rm -f "$G/orca-roles.overrides.json"
rm -f "$S/.orca-roles.json"; mv "$G/cfg.saved" "$G/orca-roles.config.json"
jq '.settings.mode = "pr-reviewer"' "$G/orca-roles.config.json" > "$G/c.tmp" && mv "$G/c.tmp" "$G/orca-roles.config.json"
try status --status; check "status: shows the saved mode" "$RC:$(printf '%s' "$OUT" | sed -n 2p)" "0:Mode: pr-reviewer"
# a hyphenated role (E2E_TESTER) and the model inherited from defaults
jq '.roles["e2e-tester"] = {title: "E2E-Tester"} | .defaults.model = "m-def"' "$G/orca-roles.config.json" > "$G/c.tmp" && mv "$G/c.tmp" "$G/orca-roles.config.json"
printf 'E2E_TESTER=h-up\nPLANNER=h-up\n' > "$G/orca-roles.env"
printf '#!/bin/sh\necho '"'"'{"result":{"terminal":{"agentIdentity":"claude"}}}'"'"'\n' > "$TMP/sbin/orca"
try status --status; check "status: hyphenated role and defaults.model" "$RC:$(printf '%s' "$OUT" | tail -n +3 | tr '\t\n' '|/')" "0:E2E-Tester|h-up|alive|m-def|-|-|-/Planner|h-up|alive|m-def|-|-|-"
# the Kit line: from VERSION and .installed, 'unknown' for what is missing; also without a team; nothing is written
printf '%s\n' 1.2.3 > "$KIT/VERSION"; printf '%s\n' 'local@main abc123' > "$KIT/.installed"; rm -f "$G/orca-roles.env"
try status --status; check "status: Kit line with VERSION and .installed, before 'No team launched'" "$RC:$(printf '%s' "$OUT" | tr '\n' '/')" "0:Kit: 1.2.3 (local@main abc123)/No team launched in this worktree."
printf 'PLANNER=h-up\n' > "$G/orca-roles.env"
try status --status; check "status: Kit line comes first, then Mode" "$RC:$(printf '%s' "$OUT" | head -2 | tr '\n' '/')" "0:Kit: 1.2.3 (local@main abc123)/Mode: pr-reviewer/"
rm -f "$KIT/.installed"; try status --status; check "status: Kit line without .installed" "$(printf '%s' "$OUT" | head -1)" "Kit: 1.2.3 (unknown)"
printf '%s\n' 'github@v2' > "$KIT/.installed"; rm -f "$KIT/VERSION"; try status --status; check "status: Kit line without VERSION" "$(printf '%s' "$OUT" | head -1)" "Kit: unknown (github@v2)"
rm -f "$KIT/.installed"
# provenance columns: from the LAST line of each role; '-' without one
printf 'PLANNER=h-up\nDEV=h-none\n' > "$G/orca-roles.env"
{ echo '{"ts":"t1","role":"dev","agent":"claude","cliVersion":"1.0.0 (Claude Code)","promptSha":"aaaaaaaffff"}'
  echo '{"ts":"t2","role":"planner","agent":"codex","cliVersion":null,"promptSha":"1234567890"}'
  echo '{"ts":"t3","role":"dev","agent":"custom","cliVersion":null,"promptSha":null}'
  echo '{"ts":"t4","role":"dev","agent":"claude","cliVersion":"9.9.9 (Claude Code)","promptSha":"bbbbbbbcccc"}'; } > "$G/orca-roles.provenance.jsonl"
S0="$(ssum 2>/dev/null)"
try status --status; check "status: provenance columns come from the last line of each role" "$RC:$(printf '%s' "$OUT" | tail -n +3 | tr '\t\n' '|/')" "0:Planner|h-up|alive|m-def|-|codex@-|1234567/Dev|h-none|alive|m-dev|-|claude@9.9.9 (Claude Code)|bbbbbbb"
check "status: provenance leaves the git dir as it was" "$([ "$(ssum 2>/dev/null)" = "$S0" ] && echo unchanged || echo CHANGED)" "unchanged"
printf 'not json\n' > "$G/orca-roles.provenance.jsonl"; try status --status
check "status: an unreadable provenance file shows '-'" "$RC:$(printf '%s' "$OUT" | tail -n +3 | tr '\t\n' '|/')" "0:Planner|h-up|alive|m-def|-|-|-/Dev|h-none|alive|m-dev|-|-|-"
rm -f "$G/orca-roles.provenance.jsonl"
try status -h; check "status: -h prints the whole header, ending at the lock and not-ready lines" "$(printf '%s\n' "$OUT" | grep -c '^# The mode of a worktree cannot change'):$(printf '%s\n' "$OUT" | tail -2 | head -1 | cut -c1-40):$(printf '%s\n' "$OUT" | tail -1 | cut -c1-30)" '1:# Only one launch runs per worktree at a:# ("Orca is not ready"), it st'
}

sec_metrics() {
# agent.sh provenance (one JSON line per start, in the git dir) and metrics.sh (tokens per role and session from Claude Code's session files)
MP="$TMP/mtproj"; MB="$TMP/mtbin"; rm -rf "$MP" "$MB" "$TMP/mtnogit" "$TMP/mtcc"; mkdir -p "$MP" "$MB" "$TMP/mtnogit"; git -C "$MP" init -q; MG="$MP/.git"
MCFG="$TMP/mt-config.json"
cat > "$MCFG" <<'J'
{ "defaults": { "mcp": "all", "agent": "claude" }, "mcpServers": {},
  "roles": { "planner": {}, "dev": { "model": "m-dev" }, "cu": { "agent": "custom", "command": "true" }, "oc": { "agent": "custom", "command": "  opencode run {model}" } } }
J
printf '#!/bin/sh\ncase "$1" in --version) echo "9.9.9 (Claude Code)"; echo second line;; *) echo "$@";; esac\n' > "$MB/claude"; chmod +x "$MB/claude"
agent_run() { (cd "$1" && HOME="$TMP/home" PATH="$MB:$PATH" ORCA_ROLES_CONFIG="$MCFG" "$TMP/home/.orca-roles/bin/agent.sh" "$2" >/dev/null 2>&1) || true; }
agent_run "$MP" dev
PF="$MG/orca-roles.provenance.jsonl"
check "provenance: one line after one start" "$(wc -l < "$PF" | tr -d ' ')" "1"
check "provenance: role, agent, model, cliVersion (first line only), promptSha" "$(jq -r '[.role, .agent, .model, .cliVersion, .promptSha] | join("|")' "$PF")" "dev|claude|m-dev|9.9.9 (Claude Code)|$(shasum "$KIT/prompts/programmer/dev.md" | cut -d' ' -f1)"
check "provenance: configSha is the sha1 of the config agent.sh read" "$(jq -r .configSha "$PF")" "$(shasum "$MCFG" | cut -d' ' -f1)"
check "provenance: UTC timestamp, kit and installed null without VERSION/.installed" "$(jq -r '[(.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")), .kit, .installed] | map(tostring) | join("|")' "$PF")" "true|null|null"
printf '%s\n' 4.5.6 > "$KIT/VERSION"; printf '%s\n' 'local@main abc' > "$KIT/.installed"
agent_run "$MP" dev; agent_run "$MP" planner
check "provenance: every start appends a line" "$(jq -r .role "$PF" | tr '\n' ',')" "dev,dev,planner,"
check "provenance: kit and installed from VERSION and .installed" "$(tail -1 "$PF" | jq -r '[.kit, .installed] | join("|")')" "4.5.6|local@main abc"
check "provenance: the planner's model is null when none is configured" "$(tail -1 "$PF" | jq -c '[.model, .role]')" '[null,"planner"]'
rm -f "$KIT/VERSION" "$KIT/.installed"
agent_run "$MP" cu
check "provenance: a custom agent has cliVersion null" "$(tail -1 "$PF" | jq -c '[.agent, .cliVersion]')" '["custom",null]'
printf '#!/bin/sh\n[ "$1" = --version ] && sleep 30\necho started\n' > "$MB/claude"
S1="$(date +%s)"; agent_run "$MP" dev; S2="$(date +%s)"
check "provenance: a claude that hangs on --version does not hang agent.sh, version null" "$([ $((S2 - S1)) -lt 20 ] && echo fast):$(tail -1 "$PF" | jq -r .cliVersion)" "fast:null"
rm -f "$MB/claude"
agent_run "$TMP/mtnogit" dev
check "provenance: outside a git repository nothing is written" "$(find "$TMP/mtnogit" -name 'orca-roles*' | wc -l | tr -d ' ')" "0"

# metrics.sh against a fixture of Claude Code session files
WTP="$(cd "$MP" && pwd -P)"; CC="$TMP/mtcc"; PD="$CC/projects/$(printf '%s' "$WTP" | tr '/.' '--')"; mkdir -p "$PD"
asst() { printf '{"type":"assistant","sessionId":"%s","cwd":"%s","version":"2.0.1","timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; }
{ printf '{"type":"user","sessionId":"s-pl","cwd":"%s","timestamp":"2026-02-01T10:00:00.000Z","message":{"role":"user","content":"Read /k/prompts/programmer/planner.md and adopt that role from now on. Mode: programmer."}}\n' "$WTP"
  asst s-pl "$WTP" 2026-02-01T10:00:05.000Z m-a 10 20 30 40; } > "$PD/s-pl.jsonl"
{ printf '{"type":"user","sessionId":"s-dev","cwd":"%s","timestamp":"2026-02-01T11:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}\n' "$WTP"
  printf '{"type":"user","sessionId":"s-dev","cwd":"%s","timestamp":"2026-02-01T11:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Read /k/prompts/programmer/common-workers.md and /k/prompts/programmer/dev.md and adopt that role from now on. Follow its instructions to the letter. Notes: see other.md"}]}}\n' "$WTP"
  asst s-dev "$WTP" 2026-02-01T11:00:05.000Z m-a 1 2 3 4; asst s-dev "$WTP" 2026-03-01T11:00:05.000Z m-b 100 200 300 400; } > "$PD/s-dev.jsonl"
{ printf '{"type":"user","sessionId":"s-other","cwd":"/elsewhere","timestamp":"2026-02-01T12:00:00.000Z","message":{"role":"user","content":"Read /k/prompts/programmer/common-workers.md and /k/prompts/programmer/tester.md and adopt that role"}}\n'
  asst s-other /elsewhere 2026-02-01T12:00:05.000Z m-a 999 999 999 999; } > "$PD/s-other.jsonl"
{ printf '{"type":"user","sessionId":"s-none","cwd":"%s","timestamp":"2026-02-01T13:00:00.000Z","message":{"role":"user","content":"hello"}}\n' "$WTP"
  asst s-none "$WTP" 2026-02-01T13:00:05.000Z m-a 5 6 7 8; printf '{"type":"summary","summary":"x"}\n'; } > "$PD/s-none.jsonl"
mx() { (cd "$MP" && HOME="$TMP/home" PATH="$MB:$PATH" CLAUDE_CONFIG_DIR="$CC" ORCA_ROLES_CONFIG="$MCFG" "$TMP/home/.orca-roles/bin/metrics.sh" "$@" 2>"$TMP/mt.err"); }
SUMQ='[.turns, .input, .output, .cacheRead, .cacheWrite] | map(tostring) | join(",")'
try mx
check "metrics: one line per role and session; the session of another cwd is ignored" "$RC:$(printf '%s\n' "$OUT" | jq -r '[.role, .session] | join(":")' | sort | tr '\n' ' ')" "0:dev:s-dev planner:s-pl unknown:s-none "
check "metrics: stdout is valid JSONL" "$(printf '%s\n' "$OUT" | jq -c . | cmp -s - <(printf '%s\n' "$OUT") && echo same)" "same"
check "metrics: the dev session sums its two turns" "$(printf '%s\n' "$OUT" | jq -r 'select(.role == "dev") | '"$SUMQ")" "2,101,202,303,404"
check "metrics: the dev line's agent, model (last turn), version, first and last" "$(printf '%s\n' "$OUT" | jq -r 'select(.role == "dev") | [.agent, .model, .version, .first, .last] | join("|")')" "claude|m-b|2.0.1|2026-02-01T11:00:05.000Z|2026-03-01T11:00:05.000Z"
check "metrics: the planner and the role-less session" "$(printf '%s\n' "$OUT" | jq -r 'select(.role == "planner" or .role == "unknown") | .role + "=" + ('"$SUMQ"')' | sort | tr '\n' ' ')" "planner=1,10,20,30,40 unknown=1,5,6,7,8 "
check "metrics: no opencode line and no warning without opencode" "$(printf '%s\n' "$OUT" | grep -c opencode):$(wc -c < "$TMP/mt.err" | tr -d ' ')" "0:0"
check "metrics: without --save nothing is written" "$([ -e "$MG/orca-roles.runs.jsonl" ] && echo written || echo none)" "none"
try mx --since 2026-02-15
check "metrics: --since keeps only later turns (the dev session loses its first one; the others are gone)" "$(printf '%s\n' "$OUT" | jq -r '.role + "=" + ('"$SUMQ"')' | tr '\n' ' ')" "dev=1,100,200,300,400 "
try mx --save
check "metrics: --save prints and appends the same lines" "$(cmp -s "$MG/orca-roles.runs.jsonl" <(printf '%s\n' "$OUT") && echo same):$(wc -l < "$MG/orca-roles.runs.jsonl" | tr -d ' ')" "same:3"
try mx --save; check "metrics: --save appends again" "$(wc -l < "$MG/orca-roles.runs.jsonl" | tr -d ' ')" "6"
try mx -h; check "metrics: -h prints the header" "$RC:$(printf '%s' "$OUT" | grep -c -e '^# Usage' -e '^#   --since' -e '^#   --save')" "0:3"
try mx --bogus; check "metrics: an unknown option fails" "$RC" "1"
# OpenCode: only with the binary on the PATH and a role that runs it
printf '#!/bin/sh\n[ "$1" = stats ] && { echo "{\\"sessions\\": 3, \\"args\\": \\"$*\\"}"; exit 0; }\nexit 1\n' > "$MB/opencode"; chmod +x "$MB/opencode"
try mx
check "metrics: one opencode line with its raw stats (not split per role)" "$(printf '%s\n' "$OUT" | jq -r 'select(.agent == "opencode") | [.role, .raw.sessions, .raw.args] | map(tostring) | join("|")'):$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "null|3|stats --json --cost --project .:4"
jq 'del(.roles.oc)' "$MCFG" > "$MCFG.x" && mv "$MCFG.x" "$MCFG"
try mx; check "metrics: no opencode line when no role runs opencode" "$(printf '%s\n' "$OUT" | grep -c opencode)" "0"
jq '.roles.oc = {agent: "opencode"}' "$MCFG" > "$MCFG.x" && mv "$MCFG.x" "$MCFG"
try mx; check "metrics: agent opencode counts too" "$(printf '%s\n' "$OUT" | grep -c opencode)" "1"
printf '#!/bin/sh\necho oops >&2; exit 1\n' > "$MB/opencode"
try mx; check "metrics: a failing opencode gives a warning on stderr and no line, exit 0" "$RC:$(printf '%s\n' "$OUT" | grep -c opencode):$(grep -c 'warning' "$TMP/mt.err")" "0:0:1"
printf '#!/bin/sh\nsleep 30\n' > "$MB/opencode"
S1="$(date +%s)"; try env ORCA_ROLES_METRICS_TIMEOUT=1 bash -c 'cd "$1" && HOME="$2" PATH="$3:$PATH" CLAUDE_CONFIG_DIR="$4" ORCA_ROLES_CONFIG="$5" "$2/.orca-roles/bin/metrics.sh" 2>/dev/null' _ "$MP" "$TMP/home" "$MB" "$CC" "$MCFG"; S2="$(date +%s)"
check "metrics: a hanging opencode is cut off" "$RC:$([ $((S2 - S1)) -lt 20 ] && echo fast):$(printf '%s\n' "$OUT" | grep -c opencode)" "0:fast:0"
rm -f "$MB/opencode"
try mx; check "metrics: the stub removed, no opencode line and no error" "$RC:$(printf '%s\n' "$OUT" | grep -c opencode):$(wc -c < "$TMP/mt.err" | tr -d ' ')" "0:0:0"
check "metrics: outside a git repository it fails with a message" "$(cd "$TMP/mtnogit" && HOME="$TMP/home" "$TMP/home/.orca-roles/bin/metrics.sh" 2>&1 >/dev/null | head -1 | cut -c1-30)" "metrics.sh: run it from the wo"
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
  "terminal show") [ -f "$TMP/m-rt" ] && { echo '{"ok":false,"error":{"code":"runtime_unavailable"}}'; exit 1; }; [ -f "$TMP/m-orphan" ] && { echo '{"result":{"terminal":{"orphaned":true,"agentIdentity":"claude"}}}'; exit 0; }; [ -f "$TMP/m-noagent" ] && { echo '{"result":{"terminal":{"handle":"x"}}}'; exit 0; }; [ -f "$TMP/m-alive" ] && { echo '{"agentIdentity":"claude"}'; exit 0; }; echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
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
check "mode_error: known but not available" "$(KIT="$PK" mode_error academic-research)" "mode 'academic-research' is not available yet"
for bad in Programmer PROGRAMMER ../x programmer/ "a b" foo "" "programmer " "pr-reviewer/../programmer" program pr programmer2 pr-reviewer-x; do
  check "mode_error rejects '$bad'" "$(KIT="$PK" mode_error "$bad")" "unknown mode '$bad' (modes: programmer, pr-reviewer, academic-research)"
done
check "mode_of: default is programmer" "$(KIT="$PK" mode_of "$PKC")" "programmer"
check "default config: settings.mode and the roles' modes" "$(jq -c '[.settings.mode, .roles.planner.modes, ([.roles | to_entries[] | select(.key != "planner" and .key != "auditor" and (.value.modes | index("academic-research") | not)) | .value.modes] | unique), .roles.auditor.modes]' "$PKC")" '["programmer","all",[["programmer"]],["programmer","pr-reviewer"]]'
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
for bad in Programmer ../x '' programmer/ "a b" foo academic-research; do
  try ml --mode "$bad"
  check "launch --mode '$bad' fails before anything opens or is saved" "$RC:$(mcreates):$(mstate)" "1:$N:$B"
done
try ml --mode Programmer; case "$OUT" in *"unknown mode 'Programmer' (modes: programmer, pr-reviewer, academic-research)"*) echo "ok   launch: unknown mode message";; *) echo "FAIL unknown mode message: $OUT"; FAIL=1;; esac
try ml --mode academic-research; case "$OUT" in *"mode 'academic-research' is not available yet"*) echo "ok   launch: unavailable mode message";; *) echo "FAIL unavailable message: $OUT"; FAIL=1;; esac
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
for o in "--mode Foo" "--mode academic-research" "--only dev,rv" "--enable dev"; do
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
# role selections belong to a mode: a different --mode drops the saved --only/--enable/--disable and keeps the saved --set
ml --mode pr-reviewer --enable rv --set settings.language=x >/dev/null; rm -f "$MG/orca-roles.env"
try ml --mode pr-reviewer --set settings.jiraHandoff=false
check "saved mode: the same --mode keeps the saved selections" "$RC:$(jq -c .enable "$MG/orca-roles.overrides.json"):$(printf '%s' "$OUT" | grep -c 'Mode changed')" '0:["rv"]:0'
rm -f "$MG/orca-roles.env"
try ml --mode programmer
check "saved mode: another --mode drops the saved selections, keeps the sets and says so" "$RC:$(mmode):$(mh):$(jq -c '[.enable,.set[].path]' "$MG/orca-roles.overrides.json"):$(printf '%s' "$OUT" | grep -c "Mode changed to programmer: this worktree's saved role selections (--only/--enable/--disable) were dropped.")" '0:programmer:PLANNER DEV ALLROLE :[[],["settings","language"],["settings","jiraHandoff"]]:1'
rm -f "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"
ml --mode pr-reviewer --set settings.language=x >/dev/null; rm -f "$MG/orca-roles.env"
try ml --mode programmer
check "saved mode: a mode change with no saved selections drops nothing and prints no note" "$RC:$(mmode):$(printf '%s' "$OUT" | grep -c 'Mode changed')" "0:programmer:0"
rm -f "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"
# the mode that counts is the worktree's effective one, also when it comes from .orca-roles.json with no saved --mode
echo '{"settings":{"mode":"pr-reviewer"}}' > "$M/.orca-roles.json"
ml --enable rv >/dev/null; rm -f "$MG/orca-roles.env"
try ml --mode programmer
check "effective mode from .orca-roles.json: --mode programmer succeeds, drops the saved enable and says so" "$RC:$(mmode):$(jq -c .enable "$MG/orca-roles.overrides.json"):$(printf '%s' "$OUT" | grep -c "Mode changed to programmer")" "0:programmer:[]:1"
rm -f "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"
ml --enable rv >/dev/null; rm -f "$MG/orca-roles.env"
try ml --mode pr-reviewer --set settings.language=x
check "effective mode from .orca-roles.json: the same --mode keeps the saved enable and prints no note" "$RC:$(mmode):$(jq -c .enable "$MG/orca-roles.overrides.json"):$(printf '%s' "$OUT" | grep -c 'Mode changed')" "0:pr-reviewer:[\"rv\"]:0"
rm -f "$M/.orca-roles.json" "$MG/orca-roles.env"; ml --reset >/dev/null; rm -f "$MG/orca-roles.env"
# a saved role that no longer exists is caught again after the merge, so a new option does not save it
echo '{"enable":["gone"]}' > "$MG/orca-roles.overrides.json"; BEFORE="$(mstate)"
try ml --set settings.language=x
check "stale saved role + a new option: rejected, the saved options and config stay unchanged" "$RC:$(printf '%s' "$OUT" | grep -c '^ERROR: unknown roles: gone\. Available: '):$([ "$(mstate)" = "$BEFORE" ] && echo same):$(jq -c . "$MG/orca-roles.overrides.json")" '1:1:same:{"enable":["gone"]}'
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
# 'orca terminal show' failing for a reason other than a stale handle: the open-team check cannot tell, so a mode change is refused
: > "$TMP/m-rt"; B="$(mstate)"; N="$(mcreates)"
try ml --mode pr-reviewer; check "terminal show unknown: a mode change with a saved team stops with 'Orca is not ready', nothing changes" "$RC:$(printf '%s' "$OUT" | grep -c 'ERROR: Orca is not ready (runtime_unavailable): cannot tell whether this worktree.s team is still open'):$(mcreates):$(mstate)" "1:1:$N:$B"
rm -f "$TMP/m-rt"
# a tab that still exists but is orphaned, or whose agent is gone, is still an open team: the mode change is refused
for st in orphan noagent; do
  : > "$TMP/m-$st"; B="$(mstate)"; N="$(mcreates)"
  try ml --mode pr-reviewer; check "open team: a tab that is $st still blocks a mode change; nothing changes" "$RC:$(printf '%s' "$OUT" | grep -c 'Close the team first'):$(mcreates):$(mstate)" "1:1:$N:$B"
  rm -f "$TMP/m-$st"
done
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

# pr-reviewer is available in the shipped kit: the default configuration opens the planner and the auditor only
PRK="$TMP/prk"; PRH="$TMP/prhome"; mkdir -p "$PRK" "$PRH"; cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$PRK/"; chmod +x "$PRK"/bin/*.sh
rm -rf "$PRK/prompts/academic-research"   # the mode is available once its planner.md exists: these checks need it unavailable
ln -sfn "$PRK" "$PRH/.orca-roles"
jq '.settings += {"kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false} | .mcpServers = {} | .defaults.params = {}' "$ROOT/config.default.json" > "$PRK/config.json"
check "mode_error: pr-reviewer is available in the shipped kit" "$(KIT="$PRK" mode_error pr-reviewer)" ""
check "mode_error: academic-research is still not available" "$(KIT="$PRK" mode_error academic-research)" "mode 'academic-research' is not available yet"
check "default config: the auditor belongs to programmer and pr-reviewer, the other workers to programmer only" "$(jq -c '[.roles.auditor.modes, ([.roles | to_entries[] | select(.key != "planner" and .key != "auditor" and (.value.modes | index("academic-research") | not)) | .value.modes] | unique)]' "$ROOT/config.default.json")" '[["programmer","pr-reviewer"],[["programmer"]]]'
PRP="$TMP/prproj"; mkdir -p "$PRP"; git -C "$PRP" init -q; PRG="$PRP/.git"; : > "$MLOG"
prl() { (cd "$PRP" && HOME="$PRH" PATH="$TMP/mbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/mbin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PRH/.orca-roles/bin/launch.sh" "$@" 2>&1); }
try prl --mode pr-reviewer; check "launch --mode pr-reviewer with the default config: PLANNER and AUDITOR only" "$RC:$(cut -d= -f1 "$PRG/orca-roles.env" | tr '\n' ' ')" "0:PLANNER AUDITOR "
check "launch pr-reviewer (default config): the auditor reads the mode's prompts" "$(cd "$PRP" && KIT="$PRK" worker_msg "$PRG/orca-roles.config.json" auditor | grep -o "Read [^ ]*common-workers.md and [^ ]*auditor.md")" "Read $PRK/prompts/pr-reviewer/common-workers.md and $PRK/prompts/pr-reviewer/auditor.md"
check "launch pr-reviewer (default config): the planner reads the mode's planner.md" "$(cd "$PRP" && KIT="$PRK" planner_msg "$PRG/orca-roles.config.json" "planner auditor" "$PRG/orca-roles.env" "" "" 0 | grep -o 'Read [^ ]*planner.md')" "Read $PRK/prompts/pr-reviewer/planner.md"
rm -f "$PRG/orca-roles.env"; try prl --reset; check "launch --reset: back to the programmer team, unchanged" "$RC:$(cut -d= -f1 "$PRG/orca-roles.env" | tr '\n' ' ')" "0:PLANNER RESEARCHER DEV TESTER AUDITOR E2E_TESTER DEPLOYER "
}

sec_research_defaults() {
# academic-research in the default configuration: roles per phase and model, the programmer and pr-reviewer teams untouched, the researcher migration on upgrade
D="$ROOT/config.default.json"
check "research-defaults: the file is valid JSON and check_config is silent" "$(jq empty "$D" && echo valid):$(check_config "$D")" "valid:"
check "research-defaults: role order, the old seven first" "$(jq -r '.roles | keys_unsorted | join(" ")' "$D")" "planner researcher dev tester auditor e2e-tester deployer sota methodology tech-verifier writer evidence rigor style dev-opencode"
check "research-defaults: each new role's modes, phases and model, with exactly those fields" "$(jq -r '.roles | to_entries[] | select(.key | IN("sota","methodology","tech-verifier","writer","evidence","rigor","style")) | "\(.key)=\(.value | [(keys_unsorted | join(",")), (.modes | join(",")), (.phases | join(",")), .model, .enabled] | join("|"))"' "$D" | tr '\n' ' ')" "sota=title,enabled,modes,phases,model|academic-research|experiment|claude-haiku-5-5|true methodology=title,enabled,modes,phases,model|academic-research|experiment|claude-opus-5-5|true tech-verifier=title,enabled,modes,phases,model|academic-research|experiment|claude-opus-5-5|true writer=title,enabled,modes,phases,model|academic-research|writing|claude-opus-5-5|true evidence=title,enabled,modes,phases,model|academic-research|writing|claude-sonnet-5-5|true rigor=title,enabled,modes,phases,model|academic-research|writing|claude-opus-5-5|true style=title,enabled,modes,phases,model|academic-research|writing|claude-sonnet-5-5|true "
check "research-defaults: researcher joins the mode in experiment and writing, nothing else changed" "$(jq -c '.roles.researcher' "$D")" '{"title":"Researcher","enabled":true,"modes":["programmer","academic-research"],"phases":["experiment","writing"],"model":"claude-opus-5-5","mcp":["context7"]}'
git -C "$ROOT" show HEAD:config.default.json > "$TMP/awd-old.json"
awt() { for m in programmer pr-reviewer; do jq -c --arg m "$m" '.settings.mode=$m' "$1" > "$TMP/awd-t.json"; enabled_roles "$TMP/awd-t.json" | while read -r r; do echo "$m/$r=$(jq -r --arg r "$r" '.roles[$r].model // "-"' "$TMP/awd-t.json")"; done; done | tr '\n' ' '; }
check "research-defaults: the programmer and pr-reviewer teams (roles, order, models) equal the previous default's" "$(awt "$D")" "$(awt "$TMP/awd-old.json")"
check "research-defaults: the programmer team is the seven old roles" "$(awt "$D" | tr ' ' '\n' | grep -c '^programmer/'):$(awt "$D" | grep -o 'programmer/[a-z0-9-]*' | tr '\n' ' ')" "7:programmer/planner programmer/researcher programmer/dev programmer/tester programmer/auditor programmer/e2e-tester programmer/deployer "
pk_setup
mkdir -p "$PK/prompts/academic-research"; echo "# planner" > "$PK/prompts/academic-research/planner.md"; echo "# cw" > "$PK/prompts/academic-research/common-workers.md"
check "research-defaults: academic-research team per phase" "$(for p in experiment writing; do jq -c --arg p "$p" '.settings.mode="academic-research" | .settings.phase=$p' "$D" > "$TMP/awd-p.json"; KIT="$PK" enabled_roles "$TMP/awd-p.json" | tr '\n' ' '; echo; done | tr '\n' '|')" "planner researcher sota methodology tech-verifier |planner researcher writer evidence rigor style |"
rm -rf "$PK/prompts/academic-research"
awu() { echo "$1" > "$TMP/awd-user.json"; upgrade_config "$D" "$TMP/awd-user.json"; }
RM() { jq -c '[.roles.researcher.modes, .roles.researcher.phases]'; }
check "upgrade_config: researcher modes [programmer] move to the new default, phases added (experiment and writing)" "$(awu '{"roles":{"researcher":{"modes":["programmer"]}}}' | RM)" '[["programmer","academic-research"],["experiment","writing"]]'
check "upgrade_config: a user's own researcher modes stay (other lists, order, all, a string)" "$(for v in '["programmer","pr-reviewer"]' '["pr-reviewer"]' '["programmer","programmer"]' '["academic-research","programmer"]' '"all"' '[]' '["programmer","academic-research"]'; do awu "{\"roles\":{\"researcher\":{\"modes\":$v}}}" | jq -c '.roles.researcher.modes'; done | tr '\n' ' ')" '["programmer","pr-reviewer"] ["pr-reviewer"] ["programmer","programmer"] ["academic-research","programmer"] "all" [] ["programmer","academic-research"] '
check "upgrade_config: a researcher without modes, or without an entry, gets the default" "$(awu '{"roles":{"researcher":{"enabled":false}}}' | jq -c '[.roles.researcher.modes, .roles.researcher.enabled]'):$(awu '{"roles":{"dev":{"model":"x"}}}' | RM)" '[["programmer","academic-research"],false]:[["programmer","academic-research"],["experiment","writing"]]'
check "upgrade_config: a user's own researcher phases stay" "$(awu '{"roles":{"researcher":{"modes":["programmer"],"phases":["writing"]}}}' | RM)" '[["programmer","academic-research"],["writing"]]'
check "upgrade_config: the user's roles keep their order and values, new roles come after" "$(awu '{"roles":{"deployer":{"model":"mine"},"dev":{"enabled":false},"custom":{"title":"C"}}}' | jq -c '[(.roles | keys_unsorted | join(",")), .roles.deployer.model, .roles.dev.enabled, .roles.custom.title]')" '["deployer,dev,custom,planner,researcher,tester,auditor,e2e-tester,sota,methodology,tech-verifier,writer,evidence,rigor,style,dev-opencode","mine",false,"C"]'
check "upgrade_config: a user's own values on a new role stay" "$(awu '{"roles":{"writer":{"model":"mine","enabled":false}}}' | jq -c '.roles.writer | [.model, .enabled, .phases, .modes]')" '["mine",false,["writing"],["academic-research"]]'
awu '{"roles":{"researcher":{"modes":["programmer"]}}}' > "$TMP/awd-up.json"
check "upgrade_config: the migrated configuration passes check_config, and its programmer team is the old one" "$(check_config "$TMP/awd-up.json"):$(enabled_roles "$TMP/awd-up.json" | tr '\n' ' ')" ":researcher planner dev tester auditor e2e-tester deployer "
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
printf '%s' '{"id":"al","description":"d","modes":"all","prompt":{"programmer":"# p\n## Report\n","pr-reviewer":"# r\n## Report\n","academic-research":"# a\n## Report\n"}}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "modes from-json: all with an object" "$RC:$(jq -c '.roles.al | [.modes, (.prompt | keys)]' "$NRC")" '0:["all",["academic-research","pr-reviewer","programmer"]]'
check "modes from-json: all writes three files" "$(for m in programmer pr-reviewer academic-research; do head -n1 "$PK/roles/$m/al.md"; done | tr '\n' ' ')" "# p # r # a "
case "$OUT" in *"mode 'academic-research' is not available yet"*) echo "ok   modes from-json: notes the unavailable mode";; *) echo "FAIL unavailable note: $OUT"; FAIL=1;; esac
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
nr_fail "a prompt value that is not a string" '{"id":"f7","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":5,"academic-research":"# a"}}'
nr_fail "a mode with a trailing newline" '{"id":"f8","description":"d","modes":"programmer\n","prompt":"# x"}'
nr_fail "an empty modes list" '{"id":"f9","description":"d","modes":[],"prompt":"# x"}'
nr_fail "modes null" '{"id":"f10","description":"d","modes":null,"prompt":"# x"}'
nr_fail "a path as a prompt key" '{"id":"f11","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-research":"# a","../x":"# b"}}'
nr_fail "an array prompt" '{"id":"f12","description":"d","prompt":["# x"]}'
nr_fail "a two-mode list with a string prompt" '{"id":"f13","description":"d","modes":["programmer","pr-reviewer"],"prompt":"# x\n## Report\n"}'
nr_fail "a blank prompt" '{"id":"f14","description":"d","prompt":"   "}'
nr_fail "the id common-workers (local)" '{"id":"common-workers","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-research":"# a"}}'
nr_fail "the id planner" '{"id":"planner","description":"d","prompt":"# x"}'
nr_fail "a path as id" '{"id":"../x","description":"d","prompt":"# x"}'

printf '%s' '{"id":"aw","description":"d","modes":"academic-research","prompt":"# a\n## Report\n"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "modes from-json: a single not-available mode is accepted with the note" "$RC:$(jq -c '.roles.aw.modes' "$NRC"):$([ -f "$PK/roles/academic-research/aw.md" ] && echo y)" '0:["academic-research"]:y'
case "$OUT" in *"Note: mode 'academic-research' is not available yet"*) echo "ok   modes from-json: the note for a single unavailable mode";; *) echo "FAIL single unavailable note: $OUT"; FAIL=1;; esac

# overwrite shrinks the modes: no orphans
touch "$PK/roles/al.md"
printf '%s' '{"id":"al","description":"d","modes":"programmer","overwrite":true,"prompt":"# p2\n## Report\n"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "modes overwrite: the modes it no longer has lose their prompts" "$RC:$([ -e "$PK/roles/pr-reviewer/al.md" ] && echo left):$([ -e "$PK/roles/academic-research/al.md" ] && echo left):$([ -e "$PK/roles/al.md" ] && echo legacy):$(head -1 "$PK/roles/programmer/al.md"):$(jq -c '.roles.al.modes' "$NRC")" '0::::# p2:["programmer"]'
printf '%s' '{"id":"fresh","description":"d","modes":"pr-reviewer","prompt":"# f\n## Report\n"}' > "$TMP/nj.json"; mkdir -p "$PK/roles/programmer"; echo keep > "$PK/roles/programmer/fresh.md"
try nrj "$TMP/nj.json"; check "modes: a new role does not delete a stray file of another mode" "$RC:$(cat "$PK/roles/programmer/fresh.md")" "0:keep"
rm -f "$PK/roles/programmer/fresh.md"

# --remove
printf '%s' '{"id":"rm-a","description":"d","modes":"all","prompt":{"programmer":"# p\n## Report\n","pr-reviewer":"# r\n## Report\n","academic-research":"# a\n## Report\n"}}' > "$TMP/nj.json"; nrj "$TMP/nj.json" >/dev/null
touch "$PK/roles/rm-a.md" "$PK/roles/programmer/rm-b.md" "$TMP/outside.md"
jq --arg o "$TMP/outside.md" '.roles["rm-a"].prompt["academic-research"] = $o' "$NRC" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$NRC"
try nrm rm-a; check "modes remove: per-mode and legacy prompts are deleted" "$RC:$(ls "$PK/roles/programmer/rm-a.md" "$PK/roles/pr-reviewer/rm-a.md" "$PK/roles/academic-research/rm-a.md" "$PK/roles/rm-a.md" 2>/dev/null | wc -l | tr -d ' '):$(jq -r '.roles | has("rm-a")' "$NRC")" "0:0:false"
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
printf '%s\n' wz-all "" "wizard all" 1 "" "" "" "" n "" "" "" "" "" "" "" "" 2 "$SRC" 4 4 y > "$TMP/nw2.in"
try nrw "$TMP/nw2.in"; check "modes wizard: all, the copy option for the 2nd and 3rd" "$RC:$(jq -c '.roles["wz-all"] | [.modes, (.prompt | keys)]' "$NRC"):$(cmp -s "$SRC" "$PK/roles/programmer/wz-all.md" && cmp -s "$SRC" "$PK/roles/pr-reviewer/wz-all.md" && cmp -s "$SRC" "$PK/roles/academic-research/wz-all.md" && echo same)" '0:["all",["academic-research","pr-reviewer","programmer"]]:same'
case "$OUT" in *"4) Copy the prompt of pr-reviewer"*) echo "ok   modes wizard: offers the copy option";; *) echo "FAIL wizard options: $OUT"; FAIL=1;; esac
case "$OUT" in *"Note: mode 'academic-research' is not available yet"*) echo "ok   modes wizard: notes the unavailable mode";; *) echo "FAIL wizard note: $OUT"; FAIL=1;; esac
case "$OUT" in *"programmer: $PH/.orca-roles/roles/programmer/wz-all.md"*"academic-research: $PH/.orca-roles/roles/academic-research/wz-all.md"*) echo "ok   modes wizard: the summary lists each mode's file";; *) echo "FAIL wizard summary: $OUT"; FAIL=1;; esac
SRC2="$TMP/nw-src2.md"; printf '# Role: W2\n\n## Report\ny\n' > "$SRC2"
printf '%s\n' wz-chain "" "wizard chain" 1 "" "" "" "" n "" "" "" "" "" "" "" "" 2 "$SRC" 2 "$SRC2" 4 y > "$TMP/nw4.in"
try nrw "$TMP/nw4.in"; check "modes wizard: the copy option copies the previous mode's prompt, not the first" "$RC:$(cmp -s "$SRC" "$PK/roles/programmer/wz-chain.md" && echo p):$(cmp -s "$SRC2" "$PK/roles/pr-reviewer/wz-chain.md" && echo r):$(cmp -s "$SRC2" "$PK/roles/academic-research/wz-chain.md" && echo a)" "0:p:r:a"
printf '%s\n' wz-bad "" "x" 2 9 > "$TMP/nw3.in"; S1="$(snap)"
try nrw "$TMP/nw3.in"; check "modes wizard: an invalid mode is refused, nothing written" "$RC:$([ "$(snap)" = "$S1" ] && echo unchanged)" "1:unchanged"

printf '%s\n' wz-byid "" "by id" 2 pr-reviewer "" "" "" n "" "" "" "" "" "" "" "" 2 "$SRC" y > "$TMP/nw5.in"
try nrw "$TMP/nw5.in"; check "modes wizard: the mode can be picked by its id" "$RC:$(jq -c '.roles["wz-byid"].modes' "$NRC")" '0:["pr-reviewer"]'
printf '%s\n' wz-dflt "" "defaults" "" "" "" "" "" n "" "" "" "" "" "" "" "" 2 "$SRC" y > "$TMP/nw6.in"
try nrw "$TMP/nw6.in"; check "modes wizard: Enter on 'in all modes or in one' and on the mode means one mode, the first (programmer)" "$RC:$(jq -c '.roles["wz-dflt"].modes' "$NRC")" '0:["programmer"]'
S6="$(cksum < "$NRC")"; printf '%s\n' wz-nosave "" "no save" 2 2 "" "" "" n "" "" "" "" "" "" "" "" 2 "$SRC" n > "$TMP/nw7.in"
try nrw "$TMP/nw7.in"; check "modes wizard: answering n to 'Save?' exits 1 with 'Cancelled' and leaves the configuration unchanged" "$RC:$(printf '%s' "$OUT" | grep -c '^Cancelled'):$(jq -r '.roles | has("wz-nosave")' "$NRC"):$([ "$(cksum < "$NRC")" = "$S6" ] && echo unchanged)" "1:1:false:unchanged"

# wizard, prompt option 1 (generate): the editor question answered n or y must not stop the wizard
printf '%s\n' '#!/bin/sh' 'echo opened > "$0.mark"' > "$TMP/fake-editor.sh"; chmod +x "$TMP/fake-editor.sh"; rm -f "$TMP/fake-editor.sh.mark"
printf '%s\n' wz-gen-n "" "gen n" 2 2 "" "" "" n "" "" "" "" "" "" "" "" 1 "mission n" "step" "" "lim" "" "rep" "" n n y > "$TMP/nwg.in"
EDITOR="$TMP/fake-editor.sh" try nrw "$TMP/nwg.in"; check "wizard option 1: answering n to the editor question saves the role, the editor stays closed" "$RC:$(jq -r '.roles["wz-gen-n"] | has("prompt")' "$NRC"):$(grep -c 'mission n' "$PK/roles/pr-reviewer/wz-gen-n.md"):$([ -e "$TMP/fake-editor.sh.mark" ] && echo opened)" "0:true:1:"
printf '%s\n' wz-gen-d "" "gen d" 2 2 "" "" "" n "" "" "" "" "" "" "" "" 1 "mission d" "step" "" "lim" "" "rep" "" n "" y > "$TMP/nwg.in"
EDITOR="$TMP/fake-editor.sh" try nrw "$TMP/nwg.in"; check "wizard option 1: the default answer to the editor question saves the role" "$RC:$(grep -c 'mission d' "$PK/roles/pr-reviewer/wz-gen-d.md"):$([ -e "$TMP/fake-editor.sh.mark" ] && echo opened)" "0:1:"
check "wizard option 1: the skeleton's Report line says the body stays complete (following the Output rules)" "$(grep -c -F 'Report with `worker_done`, following the Output rules (the body stays complete):' "$PK/roles/pr-reviewer/wz-gen-d.md")" "1"
printf '%s\n' wz-gen-y "" "gen y" 2 2 "" "" "" n "" "" "" "" "" "" "" "" 1 "mission y" "step" "" "lim" "" "rep" "" n y y > "$TMP/nwg.in"
EDITOR="$TMP/fake-editor.sh" try nrw "$TMP/nwg.in"; check "wizard option 1: answering y opens the editor and the wizard still saves the role" "$RC:$(grep -c 'mission y' "$PK/roles/pr-reviewer/wz-gen-y.md"):$([ -e "$TMP/fake-editor.sh.mark" ] && echo opened)" "0:1:opened"

# phases (academic-research only): wizard (answers: id, title, description, modes, mode, phase, then the defaults up to the prompt)
nrw_ph() {  # nrw_ph <id> <modes answer> <mode pick or -> <phase answer or ->
  local a=("$1" "" "phases $1" "$2"); [ "$3" = - ] || a+=("$3"); [ "$4" = - ] || a+=("$4")
  local t=(2 "$SRC" y); [ "$2" != 1 ] || t=(2 "$SRC" 4 4 y)
  printf '%s\n' "${a[@]}" "" "" "" n "" "" "" "" "" "" "" "" "${t[@]}" > "$TMP/nwp.in"; try nrw "$TMP/nwp.in"
}
nrw_ph ph-exp 2 3 1; check "phases wizard: academic-research, 1 = experiment, phases right after modes" "$RC:$(jq -c '.roles["ph-exp"] | [.modes, .phases]' "$NRC"):$(jq -r '.roles["ph-exp"] | keys_unsorted | join(",")' "$NRC" | grep -o 'modes,phases')" '0:[["academic-research"],["experiment"]]:modes,phases'
case "$OUT" in *"Phases (academic-research)"*"1) experiment"*"2) writing"*"3) both"*) echo "ok   phases wizard: the section lists the three options";; *) echo "FAIL phases section: $OUT"; FAIL=1;; esac
nrw_ph ph-wri 2 3 2; check "phases wizard: 2 = writing" "$RC:$(jq -c '.roles["ph-wri"].phases' "$NRC")" '0:["writing"]'
nrw_ph ph-both 2 3 3; R3="$RC:$(jq -c '.roles["ph-both"] | has("phases")' "$NRC")"; nrw_ph ph-def 2 3 ""; check "phases wizard: 3 and the default (empty) write no phases field" "$R3:$RC:$(jq -c '.roles["ph-def"] | has("phases")' "$NRC")" "0:false:0:false"
nrw_ph ph-all 1 - 2; check "phases wizard: modes all asks it too" "$RC:$(jq -c '.roles["ph-all"] | [.modes, .phases]' "$NRC")" '0:["all",["writing"]]'
nrw_ph ph-prg 2 1 -; check "phases wizard: a programmer role gets no question and no field" "$RC:$(jq -c '.roles["ph-prg"] | has("phases")' "$NRC"):$(printf '%s' "$OUT" | grep -c 'Phases')" "0:false:0"
S4="$(snap)"; for bad in 4 0 x; do nrw_ph ph-bad 2 3 "$bad"; check "phases wizard: the answer '$bad' is refused, nothing written" "$RC:$([ "$(snap)" = "$S4" ] && echo unchanged)" "1:unchanged"; done

# phases: --from-json
nr_ph() {  # <id> <modes json fragment> <phases json>
  printf '%s' '{"id":"'"$1"'","description":"d",'"$2"'"phases":'"$3"',"prompt":"# a\n## Report\n"}' > "$TMP/nj.json"; try nrj "$TMP/nj.json"
}
nr_ph pj-aw '"modes":"academic-research",' '["experiment","writing"]'; check "phases from-json: academic-research with both phases, right after modes" "$RC:$(jq -c '.roles["pj-aw"] | [.modes, .phases]' "$NRC"):$(jq -r '.roles["pj-aw"] | keys_unsorted | join(",")' "$NRC" | grep -o 'modes,phases')" '0:[["academic-research"],["experiment","writing"]]:modes,phases'
nr_ph pj-list '"modes":["academic-research"],' '["writing"]'; check "phases from-json: a one-element modes list" "$RC:$(jq -c '.roles["pj-list"].phases' "$NRC")" '0:["writing"]'
printf '%s' '{"id":"pj-all","description":"d","modes":"all","phases":["experiment"],"prompt":{"programmer":"# p\n## Report\n","pr-reviewer":"# r\n## Report\n","academic-research":"# a\n## Report\n"}}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "phases from-json: modes all" "$RC:$(jq -c '.roles["pj-all"].phases' "$NRC")" '0:["experiment"]'
printf '%s' '{"id":"pj-none","description":"d","modes":"academic-research","prompt":"# a\n## Report\n"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "phases from-json: no phases, no field" "$RC:$(jq -c '.roles["pj-none"] | has("phases")' "$NRC")" "0:false"
S5="$(snap)"
nr_ph_fail() {  # <name> <modes fragment> <phases json>
  nr_ph pj-bad "$2" "$3"; check "phases from-json rejects $1, nothing written" "$RC:$([ "$(snap)" = "$S5" ] && echo unchanged)" "1:unchanged"
}
nr_ph_fail "phases on a programmer role" '"modes":"programmer",' '["experiment"]'
nr_ph_fail "phases on a role without modes" '' '["writing"]'
nr_ph_fail "phases on another mode" '"modes":["pr-reviewer"],' '["writing"]'
nr_ph_fail "phases null on a programmer role" '"modes":"programmer",' 'null'
nr_ph_fail "an empty list" '"modes":"academic-research",' '[]'
nr_ph_fail "a string" '"modes":"academic-research",' '"experiment"'
nr_ph_fail "an unknown phase" '"modes":"academic-research",' '["experiment","review"]'
nr_ph_fail "a non-string phase" '"modes":"all",' '[1]'
nr_ph_fail "null on academic-research" '"modes":"academic-research",' 'null'
case "$OUT" in *"Invalid"*|*"phases"*) echo "ok   phases from-json: says why";; *) echo "FAIL phases message: $OUT"; FAIL=1;; esac
nr_ph pj-bad '"modes":"programmer",' '["writing"]'; case "$OUT" in *"phases is only for mode academic-research"*) echo "ok   phases from-json: the refusal message";; *) echo "FAIL phases refusal: $OUT"; FAIL=1;; esac

# --repo layout
NR="$TMP/nrm-repo"; mkdir -p "$NR"; cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$NR/"
rm -rf "$NR/prompts/academic-research"   # the mode is available once its planner.md exists: these checks need it unavailable
nrr() { (cd "$TMP" && HOME="$PH" "$PKL/bin/new-role.sh" "$@" 2>&1); }
nrr_w() { (cd "$TMP" && HOME="$PH" NEW_ROLE_TTY="$1" "$PKL/bin/new-role.sh" --repo "$NR" < /dev/null 2>&1); }
printf '%s' '{"id":"rp","description":"d","modes":"pr-reviewer","prompt":"# r\n## Report\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: prompts/<mode>/<id>.md (folder created), no prompt field" "$RC:$([ -f "$NR/prompts/pr-reviewer/rp.md" ] && echo y):$(jq -c '.roles.rp | [.modes, .prompt]' "$NR/config.default.json")" '0:y:[["pr-reviewer"],null]'
check "modes --repo: nothing in the installation" "$([ -e "$PK/roles/pr-reviewer/rp.md" ] && echo local)" ""
printf '%s' '{"id":"rp-all","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-research":"# a"}}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: all writes three files" "$RC:$(ls "$NR/prompts/programmer/rp-all.md" "$NR/prompts/pr-reviewer/rp-all.md" "$NR/prompts/academic-research/rp-all.md" | wc -l | tr -d ' ')" "0:3"
# the installed kit's own files are left alone by --repo overwrite/remove (T3), and the clone's availability decides the note (D4)
mkdir -p "$PK/roles"; echo inst > "$PK/roles/rp-all.md"
printf '%s' '{"id":"rp-all","description":"d","modes":"programmer","overwrite":true,"prompt":"# p2\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"
check "modes --repo overwrite: lost modes are listed, not deleted; the installed legacy file stays" "$RC:$(ls "$NR/prompts/pr-reviewer/rp-all.md" "$NR/prompts/academic-research/rp-all.md" | wc -l | tr -d ' '):$(cat "$PK/roles/rp-all.md")" "0:2:inst"
case "$OUT" in *"prompts/pr-reviewer/rp-all.md is no longer used by 'rp-all'; remove it with: git -C $NR rm prompts/pr-reviewer/rp-all.md"*"prompts/academic-research/rp-all.md is no longer used"*) echo "ok   modes --repo overwrite: tells how to remove them with git";; *) echo "FAIL repo overwrite listing: $OUT"; FAIL=1;; esac
printf '%s' '{"id":"rp-aw","description":"d","modes":"academic-research","prompt":"# a\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; case "$OUT" in *"Note: mode 'academic-research' is not available yet"*) echo "ok   modes --repo: availability is checked in the clone, not the installation";; *) echo "FAIL repo availability note: $OUT"; FAIL=1;; esac
try nrr --remove rp-aw --repo "$NR"
# D1: kit files cannot be taken over
echo kit > "$NR/prompts/programmer/common-workers.md"; echo kit > "$NR/prompts/pr-reviewer/common-workers.md"; echo kit > "$NR/prompts/programmer/lone.md"
R0="$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)"
printf '%s' '{"id":"common-workers","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-research":"# a"}}' > "$TMP/nj.json"
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
echo kit > "$NR/prompts/academic-research/lone2.md"; R1="$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)"
printf '%s' '{"id":"lone2","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-research":"# a"}}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: a file in a later mode blocks a new role, nothing written" "$RC:$(printf '%s' "$OUT" | grep -q "prompts/academic-research/lone2.md already exists" && echo msg):$([ "$(cat "$NR/config.default.json" "$NR"/prompts/*/*.md | cksum)" = "$R1" ] && echo unchanged)" "1:msg:unchanged"
rm -f "$NR/prompts/academic-research/lone2.md"
rm -f "$NR/prompts/programmer/lone.md"; try nrr --remove wz-repo --repo "$NR"
try nrr --remove rp --repo "$NR"; try nrr --remove rp-all --repo "$NR"
check "modes --repo: --remove deletes every mode's prompt" "$(ls "$NR"/prompts/*/rp.md "$NR"/prompts/*/rp-all.md 2>/dev/null | wc -l | tr -d ' '):$(find "$NR/prompts/programmer" -name '*.md' | wc -l | tr -d ' ')" "0:10"
check "modes --repo: --remove --repo leaves the installed legacy file" "$(cat "$PK/roles/rp-all.md" 2>/dev/null)" "inst"
printf '%s' '{"id":"dev","description":"d","modes":"pr-reviewer","overwrite":true,"prompt":"# r\n## Report\n"}' > "$TMP/nj.json"
try nrr --from-json "$TMP/nj.json" --repo "$NR"; check "modes --repo: overwriting a default role with fewer modes keeps the lost mode's prompt and lists it" "$RC:$([ -e "$NR/prompts/programmer/dev.md" ] && echo left):$([ -f "$NR/prompts/pr-reviewer/dev.md" ] && echo y):$(jq -c '.roles.dev.modes' "$NR/config.default.json"):$(printf '%s' "$OUT" | grep -c "prompts/programmer/dev.md is no longer used by 'dev'; remove it with: git -C $NR rm prompts/programmer/dev.md")" '0:left:y:["pr-reviewer"]:1'
# the git hint quotes a clone path with a space
NS="$TMP/my clone"; mkdir -p "$NS"; cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$NS/"
rm -rf "$NS/prompts/academic-research"   # the mode is available once its planner.md exists: these checks need it unavailable
git -C "$NS" init -q && git -C "$NS" add -A && git -C "$NS" -c user.name=t -c user.email=t@t commit -q -m init
printf '%s' '{"id":"rp-sp","description":"d","modes":"all","prompt":{"programmer":"# p","pr-reviewer":"# r","academic-research":"# a"}}' > "$TMP/nj.json"
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
# the old mode id (academic-writer) is an alias of academic-research: same result as the new id plus one note, and nothing is written or deleted under the old name
AWN="Note: mode 'academic-writer' is now called 'academic-research'; the old name works until the next version."
mkdir -p "$PK/roles/academic-research"; echo live > "$PK/roles/academic-research/ali-keep.md"; ln -sfn academic-research "$PK/roles/academic-writer"
printf '%s' '{"id":"ali","description":"d","modes":"academic-writer","phases":["writing"],"prompt":"# a\n## Report\n"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "alias from-json: modes academic-writer (and phases) is saved as academic-research, one note naming the JSON file, prompt only in the new folder" "$RC:$(jq -c '.roles.ali | [.modes, .phases, (.prompt | keys)]' "$NRC"):$(printf '%s\n' "$OUT" | grep -c "^$AWN Found in: $TMP/nj.json. Update it to academic-research.\$"):$(ls "$PK/roles/academic-research/ali.md" 2>/dev/null | wc -l | tr -d ' ')" '0:[["academic-research"],["writing"],["academic-research"]]:1:1'
printf '%s' '{"id":"ali","description":"d","modes":"academic-writer","overwrite":true,"prompt":"# a2\n## Report\n"}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; check "alias from-json: overwriting a role that stays in academic-research keeps its prompt, though the old folder name is a symlink to the new one" "$RC:$(head -n1 "$PK/roles/academic-research/ali.md"):$(cat "$PK/roles/academic-research/ali-keep.md")" "0:# a2:live"
rm -f "$PK/roles/academic-writer" "$PK/roles/academic-research/ali-keep.md"
printf '%s' '{"id":"alp","description":"d","modes":"all","prompt":{"programmer":"# p\n## Report\n","pr-reviewer":"# r\n## Report\n","academic-writer":"# old\n## Report\n"}}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; R1="$RC:$(head -n1 "$PK/roles/academic-research/alp.md"):$(printf '%s\n' "$OUT" | grep -c '^Note: mode .academic-writer.'):$([ -e "$PK/roles/academic-writer" ] && echo oldfolder || true)"
printf '%s' '{"id":"alq","description":"d","modes":"all","prompt":{"programmer":"# p\n## Report\n","pr-reviewer":"# r\n## Report\n","academic-writer":"# old\n## Report\n","academic-research":"# new\n## Report\n"}}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; R2="$RC:$(head -n1 "$PK/roles/academic-research/alq.md"):$(jq -c '.roles.alq.prompt | keys' "$NRC")"
printf '%s' '{"id":"aln","description":"d","modes":"all","prompt":{"programmer":"# p\n## Report\n","pr-reviewer":"# r\n## Report\n","academic-research":"# new\n## Report\n"}}' > "$TMP/nj.json"
try nrj "$TMP/nj.json"; R3="$RC:$(printf '%s\n' "$OUT" | grep -c 'Note: mode .academic-writer' || true)"
check "alias from-json: a prompt keyed by the old id is written for academic-research (one note, no old folder); with both keys the new one wins; no old id, no note" "$R1|$R2|$R3" '0:# old:1:|0:# new:["academic-research","pr-reviewer","programmer"]|0:0'
printf '%s' '{"id":"alb","description":"d","modes":"pr-reviewer","phases":["writing"],"prompt":"# a\n## Report\n"}' > "$TMP/nj.json"; S5="$(snap)"
try nrj "$TMP/nj.json"; check "alias from-json: phases outside academic-research says academic-research and writes nothing" "$RC:$(printf '%s\n' "$OUT" | grep -c '^phases is only for mode academic-research (the other modes have no phases)$'):$([ "$(snap)" = "$S5" ] && echo unchanged)" "1:1:unchanged"
nrw_ph al-wiz 2 academic-writer 1; check "alias wizard: typing academic-writer as the mode saves academic-research, prints one note and asks the phases" "$RC:$(jq -c '.roles["al-wiz"] | [.modes, .phases]' "$NRC"):$(printf '%s\n' "$OUT" | grep -c "^$AWN Found in: the mode typed. Update it to academic-research.\$"):$(printf '%s\n' "$OUT" | grep -c 'Phases (academic-research)')" '0:[["academic-research"],["experiment"]]:1:1'
rm -rf "$PK/config.json" "$PK/roles" "$PK/prompts/pr-reviewer"   # the kit copy is shared with other sections
}

sec_planner_skill() {
# The Planner's skill: plugin, new-role --from-json, per-worktree instructions and plugin loading
jq -e '.name == "orca-roles"' "$ROOT/plugin/.claude-plugin/plugin.json" >/dev/null && echo "ok   plugin.json valid" || { echo "FAIL plugin.json"; FAIL=1; }
check "skill: name in the frontmatter" "$(sed -n 2p "$ROOT/plugin/skills/team/SKILL.md")" "name: team"
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
printf '%s' '{"id":"cm-role","description":"d","common":"{kit}/prompts/programmer/common-peon.md","prompt":"# Role: CM\n\n## Report\nx\n"}' > "$TMP/role5.json"
try newrole "$TMP/role5.json"; check "from-json: keeps common" "$RC $(jq -r '.roles["cm-role"].common' "$KIT/config.json")" "0 {kit}/prompts/programmer/common-peon.md"
jq 'del(.roles["cm-role"])' "$KIT/config.json" > "$TMP/c.tmp" && mv "$TMP/c.tmp" "$KIT/config.json"; rm -f "$KIT/roles/programmer/cm-role.md"
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
  "terminal show") echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
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
# The repo is a Claude Code marketplace whose plugin is the kit's own
check "marketplace: lists the orca-roles plugin from ./plugin" "$(jq -r '.plugins[] | "\(.name) \(.source)"' "$ROOT/.claude-plugin/marketplace.json")" "orca-roles ./plugin"
check "marketplace: same name as the plugin" "$(jq -r '.plugins[0].name' "$ROOT/.claude-plugin/marketplace.json")" "$(jq -r '.name' "$ROOT/plugin/.claude-plugin/plugin.json")"

check "defaults: Tester maxSelfMutants and Auditor rejectSeverity" "$(jq -c '[.roles.tester.params.maxSelfMutants, .roles.auditor.params.rejectSeverity]' "$ROOT/config.default.json")" '[3,"high"]'
echo "ok   marketplace and defaults"
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
  "terminal show") echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
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
rm -f "$KIT/prompts/programmer/cu.md" "$KIT/prompts/programmer/tst.md"
}

sec_agent_flags() {
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
check "agent.sh claude: one line in the system prompt that asks for the role after /clear" "$(printf '%s\n' "$OUT" | grep -A1 -x -- --append-system-prompt | tail -1)" "$(HOME="$TMP/home" KIT="$TMP/home/.orca-roles" role_anchor "$CFGT" tester)"
case "$(HOME="$TMP/home" KIT="$TMP/home/.orca-roles" role_anchor "$CFGT" tester)" in (*"after /clear"*"$TMP/home/.orca-roles/bin/clean.sh --msg tester"*) echo "ok   role_anchor: names the role and the command";; (*) echo "FAIL role_anchor"; FAIL=1;; esac
check "agent.sh leaves pre-seeded scratch content intact" "$([ -f "$SDT/f" ] && [ -f "$SDT/sub/g" ] && [ -f "$SDT/.hidden" ] && echo y)" "y"
# agent.sh: workers cannot edit the kit (deny rules for the folders --add-dir exposes), the Planner can; the scratch folders stay writable
KH="$TMP/home/.orca-roles"; KR="${KH#/}"   # the kit as agent.sh sees it, and as the "//" rules write it
DENY="$(printf '%s\n' "$OUT" | awk '$0 == "--disallowedTools" { on = 1; next } /^--/ { on = 0 } on')"   # tester's argv, one per line
check "agent.sh worker: deny rules for the kit's prompts, roles, scripts, plugin and configuration" "$(printf '%s\n' "$DENY" | tr '\n' ' ')" "Edit(//$KR/prompts/**) Edit(//$KR/roles/**) Edit(//$KR/bin/**) Edit(//$KR/plugin/**) Edit(//$KR/config.json) Edit(//$KR/config.default.json) "
BAD=0; while IFS= read -r r; do d="${r#Edit(/}"; d="${d%\)}"; d="${d%/\*\*}"; case "$SDT/" in "$d/"*) BAD=1;; esac; done <<EOF_DENY
$DENY
EOF_DENY
check "agent.sh worker: no deny rule covers the role's scratch folder" "$BAD:$(printf '%s' "$SDT" | grep -c "^$KH/tmp/")" "0:1"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" tx)"
check "agent.sh worker: a role's own --settings does not drop the deny rules" "$(printf '%s\n' "$OUT" | grep -c '^Edit(//')" "6"
OUT="$(cd "$TMP" && HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" ORCA_ROLES_CONFIG="$KIT/config.json" "$TMP/home/.orca-roles/bin/agent.sh" planner)"
check "agent.sh: the Planner gets no deny rules (it edits the configuration for the user)" "$(printf '%s\n' "$OUT" | grep -c -e '--disallowedTools' -e '^Edit(')" "0"
rm -f "$TMP/fakebin/claude" "$TMP/fakebin/codex" "$TMP/fakebin/nice"
}

sec_restart() {
# After a restart, Orca restores the tabs with new handles: the kit finds each one by its ptyId, reads the resumed session and reopens the role with it
RP="$TMP/rproj"; rm -rf "$RP" "$TMP/rbin"; mkdir -p "$RP" "$TMP/rbin"; git -C "$RP" init -q -b main
printf 'PLANNER=old-pl\nDEV=old-dev\nTST=old-tst\n' > "$RP/.git/orca-roles.env"
printf 'PLANNER=wt@@p1\nDEV=wt@@p2\nTST=wt@@p3\n' > "$RP/.git/orca-roles.pty"
RLOG="$TMP/rorca.log"; : > "$RLOG"
cat > "$TMP/rbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$RLOG"
case "\$1 \$2" in
  "terminal list") echo '{"terminals":[{"handle":"rs-pl","ptyId":"wt@@p1","title":"x"},{"handle":"rs-dev","ptyId":"wt@@p2","title":"y"},{"handle":"other","ptyId":"wt@@p9","title":"z"}]}';;
  "terminal create") while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; echo "{\"handle\":\"new-\$t\"}";;
  "terminal show") case "\$*" in *old-*) echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;; *new-Planner*) echo '{"result":{"terminal":{"ptyId":"wt@@n1","agentIdentity":"claude"}}}';; *new-Dev*) echo '{"result":{"terminal":{"ptyId":"wt@@n2","agentIdentity":"claude"}}}';; *) echo '{"result":{"terminal":{"ptyId":"wt@@n3","agentIdentity":"claude"}}}';; esac;;
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
PRB="$TMP/restart-pr-prompts"; rm -rf "$PRB"; [ ! -d "$KIT/prompts/pr-reviewer" ] || cp -R "$KIT/prompts/pr-reviewer" "$PRB"
mkdir -p "$KIT/prompts/pr-reviewer"; : > "$KIT/prompts/pr-reviewer/planner.md"; cp "$KIT/config.json" "$RP/.git/orca-roles.config.json"
HB="$(cat "$RP/.git/orca-roles.env" "$RP/.git/orca-roles.pty" "$RP/.git/orca-roles.config.json" | cksum)"; : > "$RLOG"
OUT="$(cd "$RP" && HOME="$TMP/home" PATH="$TMP/rbin:$PATH" ORCA_ROLES_AGENT_CHECKS=1 ORCA_ROLES_KICKOFF="$TMP/rbin/kickoff" "$TMP/home/.orca-roles/bin/launch.sh" --mode pr-reviewer 2>&1)" && RC=0 || RC=$?
check "restart: restored tabs block a mode change; nothing saved, closed or opened" "$RC:$(grep -cE 'terminal (close|create)' "$RLOG" || true):$(cat "$RP/.git/orca-roles.env" "$RP/.git/orca-roles.pty" "$RP/.git/orca-roles.config.json" | cksum):$([ -e "$RP/.git/orca-roles.overrides.json" ] && echo ovr)" "1:0:$HB:"
case "$OUT" in *"Close the team first"*) echo "ok   restart: the mode change error explains it";; *) echo "FAIL restart mode change: $OUT"; FAIL=1;; esac
rm -rf "$KIT/prompts/pr-reviewer"; [ ! -d "$PRB" ] || cp -R "$PRB" "$KIT/prompts/pr-reviewer"; rm -f "$RP/.git/orca-roles.config.json"
OUT="$(cd "$RP" && HOME="$TMP/home" PATH="$TMP/rbin:$PATH" ORCA_ROLES_AGENT_CHECKS=1 ORCA_ROLES_SESSION_OF="$TMP/rbin/session-of" ORCA_ROLES_KICKOFF="$TMP/rbin/kickoff" "$TMP/home/.orca-roles/bin/launch.sh" 2>&1)"
case "$OUT" in *"Orca restored the tab of Planner after a restart (rs-pl) without the kit's settings; reopening it with its conversation (11111111-2222-3333-4444-555555555555)"*) echo "ok   restart: restored Planner tab recognized by ptyId";; *) echo "FAIL restart planner: $OUT"; FAIL=1;; esac
case "$OUT" in *"Orca restored the tab of Dev after a restart (rs-dev), but its session could not be read"*) echo "ok   restart: restored tab without a readable session starts fresh";; *) echo "FAIL restart dev: $OUT"; FAIL=1;; esac
case "$OUT" in *"The previous tab of Tst (old-tst) no longer exists"*) echo "ok   restart: a tab Orca did not restore starts fresh";; *) echo "FAIL restart tst: $OUT"; FAIL=1;; esac
check "restart: the restored tabs are closed, nothing else" "$(grep -E 'terminal close' "$RLOG" | sed 's/ --tab --json//' | tr '\n' ' ')" "terminal close --terminal rs-pl terminal close --terminal rs-dev "
check "restart: the Planner reopens with --resume and the kit's launcher" "$(grep -c "agent.sh' planner --resume 11111111-2222-3333-4444-555555555555 --json" "$RLOG")" "1"
check "restart: Dev reopens without --resume" "$(grep -c "agent.sh' dev --json" "$RLOG")" "1"
check "restart: new handles saved" "$(cut -d= -f2 "$RP/.git/orca-roles.env" | tr '\n' ' ')" "new-Planner new-Dev new-Tst "
check "restart: new terminal identities saved" "$(cut -d= -f2 "$RP/.git/orca-roles.pty" | tr '\n' ' ')" "wt@@n1 wt@@n2 wt@@n3 "
sleep 1; check "restart: kickoff gets the resumed and the remembered roles" "$(cut -d" " -f2- "$TMP/rkick.args" | sed "s#$RP/.git#GD#g")" "GD/orca-roles.env GD/orca-roles.config.json  planner dev tst  dev tst  planner "
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

# settings.trust: trust_of picks "worktree" or "never" (default by mode); an invalid value warns and counts as "never"
TO="$TF/to.json"
tof() { printf '%s' "$1" > "$TO"; trust_of "$TO" 2>&1 | tr '\n' '|'; }
check "trust_of: no setting, programmer or no mode -> worktree" "$(tof '{"settings":{"mode":"programmer"}}')$(tof '{}')" "worktree|worktree|"
check "trust_of: no setting, academic-research -> worktree; pr-reviewer -> never" "$(tof '{"settings":{"mode":"academic-research"}}')$(tof '{"settings":{"mode":"pr-reviewer"}}')" "worktree|never|"
check "trust_of: an explicit value beats the mode" "$(tof '{"settings":{"mode":"pr-reviewer","trust":"worktree"}}')$(tof '{"settings":{"trust":"never"}}')" "worktree|never|"
check "trust_of: invalid value (string, number, list) -> warning and never" "$(tof '{"settings":{"trust":"always"}}' | grep -c '^Warning.*never') $(tof '{"settings":{"trust":3}}' | grep -c Warning) $(tof '{"settings":{"trust":["worktree"]}}' | grep -c Warning)" "1 1 1"
check "trust_of: null counts as unset" "$(tof '{"settings":{"trust":null,"mode":"pr-reviewer"}}')" "never|"
# trust_folder records the folder it marked once, and only when it changed ~/.claude.json
H="$TF/h-rec"; mkdir -p "$H"; echo "$TFJ" > "$H/.claude.json"; rm -f "$TF/kit/trusted.list"; tf_run "$H"; tf_run "$H"
check "trust_folder: the marked folder is recorded once in trusted.list" "$(cat "$TF/kit/trusted.list" 2>/dev/null)" "$TFD"
H="$TF/h-rec2"; mkdir -p "$H"; echo "{\"projects\":{\"$TFD\":{\"hasTrustDialogAccepted\":true}}}" > "$H/.claude.json"; rm -f "$TF/kit/trusted.list"; tf_run "$H"
check "trust_folder: already trusted by the user -> not recorded" "$([ -e "$TF/kit/trusted.list" ] && echo recorded || echo none)" "none"
H="$TF/h-rec3"; mkdir -p "$H"; rm -f "$TF/kit/trusted.list"; tf_run "$H"
check "trust_folder: no ~/.claude.json -> nothing recorded" "$([ -e "$TF/kit/trusted.list" ] && echo recorded || echo none)" "none"

# launch.sh end to end with a fake orca: who gets marked
pk_setup
mkdir -p "$PK/prompts/pr-reviewer"; for f in planner common-workers rv; do echo "# $f" > "$PK/prompts/pr-reviewer/$f.md"; done
cat > "$PK/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner", "modes": "all" }, "dev": { "title": "Dev" }, "tester": { "title": "Tester", "enabled": false },
             "deployer": { "title": "Deployer", "enabled": false }, "rv": { "title": "Rv", "modes": ["pr-reviewer"] } } }
J
TW="$TMP/tproj"; mkdir -p "$TW" "$TMP/tbin"; git -C "$TW" init -q; TWP="$(cd "$TW" && pwd -P)"
cat > "$TMP/tbin/orca" <<'EOS'
#!/bin/sh
case "$1 $2" in
  "terminal create") while [ $# -gt 0 ]; do [ "$1" = --title ] && t="$2"; shift; done; echo "{\"handle\":\"h-$t\"}";;
  "terminal show") echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
esac
exit 0
EOS
chmod +x "$TMP/tbin/orca"; printf '#!/bin/sh\nexit 0\n' > "$TMP/tbin/kickoff"; chmod +x "$TMP/tbin/kickoff"
tl() { rm -f "$TW/.git/orca-roles.env"; echo "$TFJ" > "$PH/.claude.json"; rm -f "$PK/trusted.list"
  (cd "$TW" && HOME="$PH" PATH="$TMP/tbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/tbin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PKL/bin/launch.sh" --reset "$@" 2>&1); }
tlmarked() { jq -r --arg d "$TWP" '.projects[$d].hasTrustDialogAccepted // false' "$PH/.claude.json"; }
tllist() { cat "$PK/trusted.list" 2>/dev/null | tr '\n' ' '; }
INFO='will ask you to trust it'
try tl; check "trust launch: programmer by default -> marked and recorded" "$RC:$(tlmarked):$(tllist):$(printf '%s' "$OUT" | grep -c "$INFO")" "0:true:$TWP :0"
try tl --mode pr-reviewer; check "trust launch: pr-reviewer without settings.trust -> not marked, not recorded, one info line" "$RC:$(tlmarked):$(tllist):$(printf '%s' "$OUT" | grep -c "$INFO"):$(jq -c '.projects|keys' "$PH/.claude.json")" '0:false::1:["/other"]'
try tl --mode pr-reviewer --set settings.trust=worktree; check "trust launch: pr-reviewer with trust worktree -> marked and recorded" "$RC:$(tlmarked):$(tllist):$(printf '%s' "$OUT" | grep -c "$INFO")" "0:true:$TWP :0"
try tl --set settings.trust=never; check "trust launch: programmer with trust never -> not marked" "$RC:$(tlmarked):$(tllist):$(printf '%s' "$OUT" | grep -c "$INFO")" "0:false::1"
try tl --set settings.trust=sometimes; check "trust launch: invalid trust -> warning, not marked" "$RC:$(tlmarked):$(printf '%s' "$OUT" | grep -c '^Warning: settings.trust must be')" "0:false:1"

# codex: the trust override is left out with "never"
FB3="$TMP/fb3"; mkdir -p "$FB3"; printf '#!/bin/bash\nfor a in "$@"; do printf "%%s\\0" "$a"; done > "%s/argv"\n' "$FB3" > "$FB3/codex"; chmod +x "$FB3/codex"
WT3="$TMP/tw3"; mkdir -p "$WT3"
cxtrust() { printf '{"settings":%s,"defaults":{},"mcpServers":{},"roles":{"cx":{"agent":"codex","permissionMode":"auto"}}}' "$1" > "$TMP/cfg3.json"
  (cd "$WT3" && HOME="$TMP/home" PATH="$FB3:$PATH" ORCA_ROLES_CONFIG="$TMP/cfg3.json" "$TMP/home/.orca-roles/bin/agent.sh" cx >/dev/null 2>&1); tr '\0' '\n' < "$FB3/argv" | grep -c '^projects=' || true; }
check "codex trust: never -> no projects override; worktree -> kept; pr-reviewer default -> none; programmer default -> kept" "$(cxtrust '{"trust":"never"}') $(cxtrust '{"trust":"worktree"}') $(cxtrust '{"mode":"pr-reviewer"}') $(cxtrust '{}')" "0 1 0 1"

# kickoff.sh with trust "never": waits for the user, never presses Enter, never types the role into the dialog
TK="$TMP/tk"; mkdir -p "$TK/gd" "$TK/bin" "$TK/wt"; git -C "$TK/wt" init -q
cat > "$TK/bin/orca" <<'EOS'
#!/bin/sh
D="$TK"
case "$1 $2" in
  "terminal read") n=$(cat "$D/reads" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$D/reads"
    if [ -f "$D/clear_after" ] && [ "$n" -gt "$(cat "$D/clear_after")" ]; then s="ready"; else s="$(cat "$D/screen")"; fi
    jq -nc --arg s "$s" '{text: $s}';;
  "terminal send") echo "SEND $*" >> "$D/orca.log";;
esac
exit 0
EOS
chmod +x "$TK/bin/orca"
tk() {  # <extra settings json fragment> <reads before the dialog clears, or none>
  printf '{ "settings": { "kickoffTimeoutSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false%s }, "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" } } }' "$1" > "$TK/cfg.json"
  rm -f "$TK/orca.log" "$TK/reads" "$TK/clear_after" "$TK/gd/orca-roles.kicked"; : > "$TK/orca.log"; echo "Do you trust the files in this folder?" > "$TK/screen"
  [ "$2" = none ] || echo "$2" > "$TK/clear_after"
  printf 'PLANNER=hp\nDEV=hd\n' > "$TK/gd/orca-roles.env"
  (cd "$TK/wt" && TK="$TK" HOME="$TMP/home" PATH="$TK/bin:$PATH" ORCA_ROLES_KICK_SETTLE=0 ORCA_ROLES_TRUST_POLL=0.1 "$TMP/home/.orca-roles/bin/kickoff.sh" "$TK/wt" "$TK/gd/orca-roles.env" "$TK/cfg.json" "dev" "" "" "" > "$TK/out.log" 2>&1)
}
tkenter() { grep -c -- '^SEND terminal send --terminal [^ ]* --enter --json$' "$TK/orca.log" || true; }
tkrole() { grep -c -- '--text' "$TK/orca.log" || true; }
tk ', "trust": "never"' 3
check "kickoff trust never: dialog clears -> no Enter, waiting line once, role sent and marked kicked" "$(tkenter) $(grep -c 'Dev: waiting for you to answer the trust dialog in its tab' "$TK/out.log") $(tkrole) $(tr '\n' ' ' < "$TK/gd/orca-roles.kicked" 2>/dev/null)" "0 1 1 DEV=hd "
tk ', "trust": "never"' none
check "kickoff trust never: dialog never clears -> no Enter, role NOT sent, not marked, resend hint" "$(tkenter) $(tkrole) [$(cat "$TK/gd/orca-roles.kicked" 2>/dev/null)] $(grep -c 'role was NOT sent.*run roles again' "$TK/out.log") $(grep -c 'waiting for you to answer' "$TK/out.log")" "0 0 [] 1 1"
tk ', "mode": "pr-reviewer"' none
check "kickoff trust: pr-reviewer without settings.trust behaves as never" "$(tkenter) $(tkrole)" "0 0"
tk ', "trust": "worktree"' 1
check "kickoff trust worktree: the dialog is still accepted with Enter, role sent" "$(tkenter) $(tkrole) $(grep -c 'Trust dialog accepted' "$TK/out.log")" "1 1 1"
}

sec_forget_trust() {
# forget-trust.sh: removes only the kit's entries from ~/.claude.json (fake HOME, own copy of the kit)
FT="$TMP/ft"; rm -rf "$FT"; mkdir -p "$FT/home" "$FT/kit" "$FT/a" "$FT/b"; cp -R "$ROOT/bin" "$FT/kit/"
FA="$(cd "$FT/a" && pwd -P)"; FB="$(cd "$FT/b" && pwd -P)"; FC="$FT/gone-c"; FD="$FT/gone-d"
ftj() { printf '{"oauthAccount":{"email":"a@b"},"numStartups":3,"projects":{"%s":{"hasTrustDialogAccepted":true,"x":1},"%s":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":true},"%s":{"hasTrustDialogAccepted":true}}}' "$FA" "$FB" "$FC" "$FD" > "$FT/home/.claude.json"; printf '%s\n%s\n%s\n' "$FA" "$FB" "$FC" > "$FT/kit/trusted.list"; }
ft() { (cd "$FT/a" && env -i HOME="$FT/home" KIT="$FT/kit" PATH="$PATH" /bin/bash "$FT/kit/bin/forget-trust.sh" "$@" 2>&1); }
ftkeys() { jq -r '.projects | keys[] | split("/") | last' "$FT/home/.claude.json" | tr '\n' ' '; }
ftwithout() { jq -S -c --arg d "$1" 'del(.projects[$d])' "$FT/orig.json" | cmp -s - <(jq -S -c . "$FT/home/.claude.json") && echo same || echo DIFF; }
ftj; cp "$FT/home/.claude.json" "$FT/orig.json"; cp "$FT/kit/trusted.list" "$FT/orig.list"
OUT="$(ft --dry-run)"
check "forget-trust --dry-run: prints what it would remove, writes nothing" "$(cmp -s "$FT/home/.claude.json" "$FT/orig.json" && echo same) $(cmp -s "$FT/kit/trusted.list" "$FT/orig.list" && echo same) $(printf '%s' "$OUT" | grep -c "^Would remove projects\[$FA\]") $(printf '%s' "$OUT" | grep -c "^Would remove $FA from")" "same same 1 1"
OUT="$(ft)"
check "forget-trust: removes only this worktree's entry; the other keys are equal under jq -S; the list loses that line" "$(ftkeys)| $(ftwithout "$FA") $(tr '\n' ' ' < "$FT/kit/trusted.list")" "b gone-c gone-d | same $FB $FC "
ftj
OUT="$(ft --stale --dry-run)"
check "forget-trust --stale --dry-run: names the recorded missing folder only, writes nothing" "$(cmp -s "$FT/home/.claude.json" "$FT/orig.json" && echo same) $(cmp -s "$FT/kit/trusted.list" "$FT/orig.list" && echo same) $(printf '%s' "$OUT" | grep -c "$FC") $(printf '%s' "$OUT" | grep -c "$FD")" "same same 2 0"
OUT="$(ft --stale)"
check "forget-trust --stale: removes only recorded missing folders; unrecorded, existing and other keys stay" "$(ftkeys)| $(ftwithout "$FC") $(tr '\n' ' ' < "$FT/kit/trusted.list")" "a b gone-d | same $FA $FB "
OUT="$(ft --stale)"
check "forget-trust --stale: a second run has nothing to do" "$OUT" "No recorded folder is missing."
ftj; printf '{ not json' > "$FT/home/.claude.json"; cp "$FT/home/.claude.json" "$FT/bad.json"; OUT="$(ft; echo "rc=$?")"
check "forget-trust: invalid ~/.claude.json -> warning, untouched, rc 0, still listed" "$(printf '%s' "$OUT" | grep -c '^Warning') $(cmp -s "$FT/home/.claude.json" "$FT/bad.json" && echo same) $(printf '%s' "$OUT" | grep -c 'rc=0') $(grep -c . "$FT/kit/trusted.list")" "1 same 1 3"
ftj; rm -f "$FT/home/.claude.json"; OUT="$(ft; echo "rc=$?")"
check "forget-trust: missing ~/.claude.json -> not created, rc 0" "$([ -e "$FT/home/.claude.json" ] && echo created || echo none) $(printf '%s' "$OUT" | grep -c 'rc=0')" "none 1"
check "forget-trust: unknown option -> usage, rc 2" "$(ft --nope >/dev/null; echo $?)" "2"
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
agent2 cxa >/dev/null; DI="$(tr '\0' '\n' < "$FB2/argv" | grep '^developer_instructions=')"; ANC="$(cd "$WT2" && HOME="$TMP/home" KIT="$TMP/home/.orca-roles" role_anchor "$TMP/cfg2.json" cxa)"
check "codex: developer_instructions is the anchor, once, after -c" "$(printf '%s\n' "$DI" | grep -c .) $(tr '\0' '\n' < "$FB2/argv" | grep -B1 -x -- "$DI" | head -1) $(python3 -c 'import sys,tomllib; print(tomllib.loads(sys.argv[1])["developer_instructions"] == sys.argv[2])' "$DI" "$ANC")" "1 -c True"
ANC="$(cd "$WT2" && HOME="$TMP/home" KIT="$TMP/home/.orca-roles" role_anchor "$TMP/cfg2.json" ca)"
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

sec_opencode() {
# agent: "opencode": opencode-prepare.sh writes the agent file, agent.sh runs `opencode mini --agent orca-<role>`; stub opencode only
OC="$TMP/oc"; rm -rf "$OC"; mkdir -p "$OC/bin" "$OC/real/wt"; ln -sfn "$OC/real" "$OC/link"
cat > "$OC/bin/opencode" <<'EOS'
#!/bin/bash
case "$1" in
  --version) echo "opencode 9.9.9"; exit 0;;
  models) echo "p/m"; echo "p/other"; exit 0;;
esac
{ for a in "$@"; do printf '%s\n' "$a"; done; echo "PWD=$PWD"; } > "$OC_OUT"
EOS
chmod +x "$OC/bin/opencode"
git -C "$OC/real/wt" init -q; OCW="$OC/link/wt"; OCWP="$(cd "$OC/real/wt" && pwd -P)"; KITP="$(cd "$KIT" && pwd -P)"
cat > "$OC/cfg.json" <<'J'
{ "settings": { "flow": { "maxStepsPerWorker": 77 } }, "defaults": {}, "mcpServers": { "pw": { "command": "x" } },
  "roles": {
    "dev": { "title": "Dev", "agent": "opencode", "model": "p/m", "mcp": "all", "common": "{kit}/prompts/programmer/common-peon.md",
             "extraArgs": ["--x", "y z"],
             "opencode": { "steps": 5, "permissions": [ {"action": "shell", "resource": "rm *", "effect": "ask"}, {"action": "shell", "effect": "deny"}, {"action": "edit", "resource": "/x", "effect": "maybe"} ] } },
    "tester": { "title": "Tester", "agent": "opencode", "mcp": ["pw"] },
    "e2e-tester": { "title": "E2E", "agent": "opencode", "opencode": { "steps": 0 } },
    "cx": { "title": "Codex", "agent": "codex" }, "cl": { "title": "Claude" } } }
J
ocrun() { (cd "$OCW" && HOME="$TMP/home" PATH="$OC/bin:$PATH" OC_OUT="$OC/out" ORCA_ROLES_CONFIG="${OCCFG:-$OC/cfg.json}" "$TMP/home/.orca-roles/bin/$1" "${@:2}" 2>&1); }
FILE="$OCW/.opencode/agents/orca-dev.md"
try ocrun agent.sh dev; check "opencode: agent.sh starts the stub (exit 0)" "$RC" "0"
check "opencode: argv is mini --agent orca-dev --model p/m + extraArgs; PWD is the physical path" "$(cat "$OC/out")" "mini
--agent
orca-dev
--model
p/m
--x
y z
PWD=$OCWP"
check "opencode: no model, no --model" "$(ocrun agent.sh tester >/dev/null; sed -n 1,4p "$OC/out" | tr '\n' ' ')" "mini --agent orca-tester PWD=$OCWP "
check "opencode: the agent file is written in the worktree" "$([ -f "$FILE" ] && echo yes)" "yes"
FM="$(awk 'NR==1 && $0=="---"{f=1;next} f&&$0=="---"{exit} f' "$FILE")"
EXPECT_FM="description: \"orca-roles Dev role\"
mode: \"primary\"
model: \"p/m\"
steps: 5
permissions:
  - {\"action\":\"*\",\"resource\":\"*\",\"effect\":\"allow\"}
  - {\"action\":\"question\",\"resource\":\"*\",\"effect\":\"deny\"}
  - {\"action\":\"shell\",\"resource\":\"git push*\",\"effect\":\"deny\"}
  - {\"action\":\"edit\",\"resource\":\"$KITP/prompts/**\",\"effect\":\"deny\"}
  - {\"action\":\"edit\",\"resource\":\"$KITP/roles/**\",\"effect\":\"deny\"}
  - {\"action\":\"edit\",\"resource\":\"$KITP/bin/**\",\"effect\":\"deny\"}
  - {\"action\":\"edit\",\"resource\":\"$KITP/plugin/**\",\"effect\":\"deny\"}
  - {\"action\":\"edit\",\"resource\":\"$KITP/config.json\",\"effect\":\"deny\"}
  - {\"action\":\"edit\",\"resource\":\"$KITP/config.default.json\",\"effect\":\"deny\"}
  - {\"action\":\"shell\",\"resource\":\"rm *\",\"effect\":\"ask\"}"
check "opencode: frontmatter is exactly the expected text (allow first, the denies, then the role's valid item)" "$FM" "$EXPECT_FM"
if python3 -c 'import yaml' 2>/dev/null; then
  check "opencode: the frontmatter parses as YAML" "$(printf '%s\n' "$FM" | python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); print(d["mode"], d["steps"], d["permissions"][0]["effect"], len(d["permissions"]))')" "primary 5 allow 10"
else echo "ok   opencode: PyYAML not installed, the frontmatter was checked as exact text only"; fi
check "opencode: the invalid permission items were reported and skipped" "$(ocrun agent.sh dev | grep -c 'skipping an invalid item')" "2"
BODY="$(awk 'NR==1{next} f{print;next} $0=="---"{f=1}' "$FILE")"
ANC="$(cd "$OCW" && HOME="$TMP/home" KIT="$TMP/home/.orca-roles" role_anchor "$OC/cfg.json" dev)"
check "opencode: body = anchor, blank, the role's common file, blank, the role's prompt" "$BODY" "$ANC

$(cat "$KIT/prompts/programmer/common-peon.md")

$(cat "$KIT/prompts/programmer/dev.md")"
OCT="$OCW/.opencode/agents/orca-tester.md"
check "opencode: without role common the body uses common-workers.md" "$(grep -cxF -- "$(head -1 "$KIT/prompts/programmer/common-workers.md")" "$OCT"):$(grep -cxF -- "$(head -1 "$KIT/prompts/programmer/common-peon.md")" "$OCT" || true)" "1:0"
# steps: role value, settings.flow default, invalid role value (left out with a warning), nothing
check "opencode: steps from settings.flow.maxStepsPerWorker when the role has none" "$(grep '^steps:' "$OCT")" "steps: 77"
try ocrun opencode-prepare.sh e2e-tester; check "opencode: an invalid role steps is reported and left out" "$RC:$(grep -c 'must be a positive integer' <<<"$OUT"):$(grep -c '^steps:' "$OCW/.opencode/agents/orca-e2e-tester.md" || true)" "0:1:0"
jq 'del(.settings.flow)' "$OC/cfg.json" > "$OC/cfg-nf.json"; OCCFG="$OC/cfg-nf.json" ocrun opencode-prepare.sh tester >/dev/null
check "opencode: no steps anywhere, no steps line" "$(grep -c '^steps:' "$OCT" || true)" "0"
jq '.settings.flow.maxStepsPerWorker = "x"' "$OC/cfg.json" > "$OC/cfg-bf.json"; OCCFG="$OC/cfg-bf.json"; try ocrun opencode-prepare.sh tester
check "opencode: an invalid flow default is reported and left out" "$RC:$(grep -c 'maxStepsPerWorker must be a positive integer' <<<"$OUT"):$(grep -c '^steps:' "$OCT" || true)" "0:1:0"
OCCFG=""
# the exclude pattern goes in once, in info/exclude; no .gitignore is created
ocrun opencode-prepare.sh dev >/dev/null; ocrun opencode-prepare.sh dev >/dev/null
check "opencode: the exclude pattern is added once and no .gitignore is touched" "$(grep -cxF '/.opencode/agents/orca-*.md' "$OC/real/wt/.git/info/exclude"):$(ls "$OC/real/wt/.gitignore" 2>/dev/null | wc -l | tr -d ' '):$(git -C "$OC/real/wt" status --short | wc -l | tr -d ' ')" "1:0:0"
check "opencode: no temp file left in the agents folder" "$(ls -A "$OCW/.opencode/agents" | grep -vc '^orca-')" "0"
# the MCP servers are not passed: a role with an mcp list gets one warning and no file
try ocrun agent.sh tester; check "opencode: a role with an mcp list gets the MCP warning, no MCP file" "$RC:$(grep -c 'does not get the kit.s MCP servers' <<<"$OUT"):$(ls "$OC/real/wt/.git" | grep -c 'orca-roles-mcp' || true)" "0:1:0"
try ocrun agent.sh dev; check "opencode: mcp \"all\" gets no warning" "$(grep -c 'MCP servers' <<<"$OUT")" "0"
check "opencode: provenance records the opencode version" "$(tail -1 "$OC/real/wt/.git/orca-roles.provenance.jsonl" | jq -r '[.agent, .cliVersion] | join(" ")')" "opencode opencode 9.9.9"
# failures: outside a repo, and agent.sh stops when the preparation fails
mkdir -p "$OC/norepo"; OCW="$OC/norepo"; try ocrun opencode-prepare.sh dev; check "opencode: outside a git repo prepare exits 1 with a message" "$RC:$(grep -c 'not inside a git repository' <<<"$OUT")" "1:1"
rm -f "$OC/out"; try ocrun agent.sh dev; check "opencode: agent.sh exits 1 and never starts opencode when prepare fails" "$RC:$([ -e "$OC/out" ] && echo started):$(grep -c 'could not prepare' <<<"$OUT")" "1::1"
OCW="$OC/link/wt"
# messages: the opencode worker message points at the system prompt; the others are the usual "Read <common> and <prompt>" one
WM="$(cd "$OCW" && HOME="$TMP/home" KIT="$TMP/home/.orca-roles" worker_msg "$OC/cfg.json" dev)"
check "opencode: worker_msg names the system prompt and the agent, with the parameters" "$(printf '%s' "$WM" | sed 's/scratchDir=[^ ]*\. /scratchDir=X. /')" "Your role (Dev) and its rules are in your system prompt (agent orca-dev); follow them to the letter. Configuration parameters: scratchDir=X. Run every orca orchestration command (and its CLI under any other name) in the foreground, as a direct shell command, and wait for it to finish: never as a background task or through a subagent, or Orca will not get your report."
for r in cx cl; do
  WM="$(cd "$OCW" && HOME="$TMP/home" KIT="$TMP/home/.orca-roles" worker_msg "$OC/cfg.json" $r)"
  check "opencode: worker_msg of $r keeps the Read-the-prompt form" "$([[ "$WM" == "Read $TMP/home/.orca-roles/prompts/programmer/common-workers.md and $TMP/home/.orca-roles/prompts/programmer/"*" and adopt that role from now on. Follow its instructions to the letter."* ]] && echo ok)" "ok"
done
check "opencode: clear_command is /new, a clearCommand wins, claude and codex unchanged" "$(clear_command "$OC/cfg.json" dev) $(jq '.roles.dev.clearCommand = "/reset"' "$OC/cfg.json" > "$OC/cfg-cc.json"; clear_command "$OC/cfg-cc.json" dev) $(clear_command "$OC/cfg.json" cl) $(clear_command "$OC/cfg.json" cx)" "/new /reset /clear /new"
jq '.roles.dev.modelError = "bad model {model}"' "$OC/cfg.json" > "$OC/cfg-me.json"
check "opencode: model_error_regex is the role's modelError (none built in)" "$(model_error_regex "$OC/cfg-me.json" dev p/m):$(model_error_regex "$OC/cfg.json" dev p/m)" "bad model p/m:"
# models.sh: `opencode models` by default; the probe is membership in that list
ocm() { (cd "$PROJ" && PATH="$OC/bin:$PATH" HOME="$TMP/home" ORCA_ROLES_CONFIG="$OC/cfg.json" "$KIT/bin/models.sh" "$@" 2>&1 | tr '\t\n' '|;'); }
check "opencode: models.sh lists the role's model first, then opencode models, deduplicated" "$(ocm dev)" "p/m;p/other;"
check "opencode: models.sh --check: in the list ok, not in it unavailable" "$(ocm dev --check --model p/other);$(ocm dev --check --model q/zzz)" "p/other|ok|-;;q/zzz|unavailable;"
# new-role.sh accepts the agent and the opencode field; an unknown agent is refused
printf '%s' '{"id":"oc-role","description":"x","agent":"opencode","model":"p/m","opencode":{"steps":9,"permissions":[]},"prompt":"# x\n## Report\n"}' > "$OC/role.json"
try newrole "$OC/role.json"; check "from-json: accepts agent opencode and keeps its opencode object" "$RC $(jq -c '.roles["oc-role"] | [.agent, .opencode]' "$KIT/config.json")" '0 ["opencode",{"steps":9,"permissions":[]}]'
printf '%s' '{"id":"oc-bad","description":"x","agent":"opencod","prompt":"# x\n## Report\n"}' > "$OC/role.json"
try newrole "$OC/role.json"; check "from-json: an unknown agent is refused naming opencode" "$RC:$(grep -c 'claude, codex, opencode or custom' <<<"$OUT")" "1:1"
# the shipped example is disabled
check "config.default.json: dev-opencode is a disabled opencode example" "$(jq -c '.roles["dev-opencode"] | [.agent, .enabled, .opencode.steps]' "$ROOT/config.default.json")" '["opencode",false,120]'
}

sec_prompt_paths() {
# Every message and launch points to existing prompt files under prompts/programmer/ (loops over ALL default roles)
pk_setup
check "prompts: every default prompt file in prompts/programmer/, none flat" "$(find "$PK/prompts/programmer" -maxdepth 1 -name '*.md' | wc -l | tr -d ' '):$(find "$PK/prompts" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" "10:0"
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
for r in $(jq -r '.roles | to_entries[] | select((.value.modes // ["programmer"]) | . == "all" or index("programmer")) | .key' "$PKC"); do
  [ "$r" = planner ] && continue
  [ "$(rstr "$PKC" "$r" agent)" = opencode ] && continue   # its message points at the system prompt: section opencode
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
check "new-role --remove --repo: only its prompt is deleted, the default prompt files remain" "$([ -e "$NR/prompts/programmer/repo-sec.md" ] && echo left):$(find "$NR/prompts/programmer" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" ":10"
# a folder that is not a clone (config.default.json but flat prompts, or no config.default.json) is refused and nothing is written
NN="$TMP/nr-notclone"; rm -rf "$NN"; mkdir -p "$NN/prompts"; cp "$ROOT/config.default.json" "$NN/"; : > "$NN/prompts/dev.md"; mkdir -p "$TMP/nr-noconf/prompts/programmer"
H0="$(cd "$NN" && find . -type f | sort | xargs shasum | shasum)"
try nr_run --from-json "$TMP/nr-role.json" --repo "$NN"; N1="$RC:$(printf '%s' "$OUT" | grep -c "$NN does not look like a clone of orca-roles." || true)"
try nr_run --from-json "$TMP/nr-role.json" --repo "$TMP/nr-noconf"; N2="$RC:$(printf '%s' "$OUT" | grep -c 'does not look like a clone of orca-roles.' || true)"
check "new-role --repo: a folder with flat prompts or without config.default.json is not a clone -> exit 1 with the message, nothing written" "$N1:$N2:$([ "$(cd "$NN" && find . -type f | sort | xargs shasum | shasum)" = "$H0" ] && echo untouched):$(ls "$TMP/nr-noconf/prompts/programmer" | wc -l | tr -d ' ')" "1:1:1:1:untouched:0"
}

sec_install_flat() {
# install.sh over a kit that still has the old flat prompts leaves only prompts/programmer/
IH="$TMP/inst-home"; mkdir -p "$IH/.orca-roles/prompts"
for f in auditor common-workers deployer dev e2e-tester planner researcher tester; do echo old > "$IH/.orca-roles/prompts/$f.md"; done
(cd "$TMP" && HOME="$IH" bash "$ROOT/install.sh" </dev/null >/dev/null 2>&1) || { echo "FAIL install.sh over old flat prompts"; FAIL=1; }
check "install.sh: no flat prompt left, every default prompt file in prompts/programmer/" "$(find "$IH/.orca-roles/prompts" -maxdepth 1 -name '*.md' | wc -l | tr -d ' '):$(find "$IH/.orca-roles/prompts/programmer" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" "0:10"
# the "Enabled" line names the mode of the installed configuration
ic() { jq "$1" "$IH/.orca-roles/config.json" > "$IH/c.tmp" && mv "$IH/c.tmp" "$IH/.orca-roles/config.json"; }
irun() { if IOUT="$(cd "$TMP" && HOME="$IH" bash "$ROOT/install.sh" </dev/null 2>"$IH/err.txt")"; then IRC=0; else IRC=$?; fi; IENA="$(printf '%s\n' "$IOUT" | grep '^Enabled')"; }
iroles() { ( . "$ROOT/bin/lib.sh"; KIT="$IH/.orca-roles"; enabled_roles "$IH/.orca-roles/config.json" | tr '\n' ' ' ); }
ic 'del(.settings.mode)'; irun
check "install.sh Enabled: no settings.mode is programmer" "$IRC:$IENA" "0:Enabled (programmer): $(iroles)"
ic '.settings.mode = "pr-reviewer"'; irun
check "install.sh Enabled: names a set mode and lists its roles" "$IRC:$IENA" "0:Enabled (pr-reviewer): $(iroles)"
ic '.settings.mode = "academic-research" | del(.settings.phase)'; irun
check "install.sh Enabled: academic-research without phase says experiment" "$IRC:$IENA" "0:Enabled (academic-research, phase experiment): $(iroles)"
ic '.settings.phase = "writing"'; irun
check "install.sh Enabled: academic-research names its phase" "$IRC:$IENA" "0:Enabled (academic-research, phase writing): $(iroles)"
# the pinned browser stack: package.json and the lockfile are copied, an installed node_modules and the browsers are kept
mkdir -p "$IH/.orca-roles/pw/node_modules/x" "$IH/.orca-roles/browsers/b"; echo keep > "$IH/.orca-roles/pw/node_modules/x/f"; echo keep > "$IH/.orca-roles/browsers/b/f"; echo old > "$IH/.orca-roles/pw/package.json"; rm -f "$IH/.orca-roles/pw/package-lock.json"
irun
check "install.sh: pw/package.json and the lockfile are copied, node_modules and browsers are kept" "$IRC:$(cmp -s "$ROOT/pw/package.json" "$IH/.orca-roles/pw/package.json" && echo p):$(cmp -s "$ROOT/pw/package-lock.json" "$IH/.orca-roles/pw/package-lock.json" && echo l):$(cat "$IH/.orca-roles/pw/node_modules/x/f" "$IH/.orca-roles/browsers/b/f" | tr '\n' ' '):$(test -x "$IH/.orca-roles/bin/e2e-browser.sh" && echo x)" "0:p:l:keep keep :x"
rm -f "$IH/.orca-roles/pw/e2e.config.js"; irun
check "install.sh: pw/e2e.config.js is copied to the kit's pw" "$IRC:$(cmp -s "$ROOT/pw/e2e.config.js" "$IH/.orca-roles/pw/e2e.config.js" && echo same)" "0:same"
for bad in '"nope"' '5' 'null' '""'; do
  ic ".settings.mode = $bad"; irun
  check "install.sh Enabled: invalid settings.mode $bad is unknown, exit 0, error on stderr" "$IRC:$IENA:$(grep -c . "$IH/err.txt" | tr -d ' ')" "0:Enabled: unknown (invalid settings.mode):1"
  check "install.sh Enabled: invalid settings.mode $bad, the install goes on" "$(printf '%s\n' "$IOUT" | grep -c '^To enable or disable roles')" "1"
done
}

sec_install_migration() {
# install.sh migrates the renamed mode academic-writer: config, prompt paths, roles folder and the compatibility links
MH="$TMP/mig-home"; MK="$MH/.orca-roles"; rm -rf "$MH"; mkdir -p "$MK"
mrun() { if MOUT="$(cd "$TMP" && HOME="$MH" bash "$ROOT/install.sh" </dev/null 2>&1)"; then MRC=0; else MRC=$?; fi; MREN="$(printf '%s\n' "$MOUT" | grep -c '^Renamed mode academic-writer to academic-research in your configuration ' || true)"; MMOV="$(printf '%s\n' "$MOUT" | grep -c '^Moved your academic-writer roles' || true)"; MWARN="$(printf '%s\n' "$MOUT" | grep -c '^WARNING: .*was not moved' || true)"; }
mstate() { ( cd "$MK" && { shasum config.json; find roles -print 2>/dev/null | sort | xargs -I{} sh -c 'if [ -L "{}" ]; then echo "{} -> $(readlink "{}")"; else echo "{}"; fi'; find roles -type f 2>/dev/null | sort | xargs shasum 2>/dev/null; } | shasum ); }
cat > "$MK/config.json" <<J
{ "settings": { "mode": "academic-writer", "phase": "writing" }, "roles": {
    "zeta": { "title": "Zeta", "modes": ["academic-writer", "programmer"], "prompt": { "academic-writer": "{kit}/roles/academic-writer/z.md", "programmer": "{kit}/roles/zeta-p.md" } },
    "k1": { "title": "K1", "prompt": "$MK/roles/academic-writer/a.md" },
    "k2": { "title": "K2", "prompt": "~/.orca-roles/prompts/academic-writer/b.md" },
    "k3": { "title": "K3", "prompt": "{home}/.orca-roles/roles/academic-writer/sub/c.md" },
    "k4": { "title": "K4", "prompt": "~/notes/roles/academic-writer/x.md" },
    "k5": { "title": "K5", "prompt": "{kit}/roles/academic-writer-extra/x.md" },
    "k6": { "title": "K6", "prompt": "{kit}/roles/foo/roles/academic-writer/x.md" },
    "k7": { "title": "K7", "prompt": "/data/prompts/academic-writer/x.md" } } }
J
mkdir -p "$MK/roles/academic-writer/sub"; echo A > "$MK/roles/academic-writer/a.md"; echo H > "$MK/roles/academic-writer/.hid"; echo C > "$MK/roles/academic-writer/sub/c.md"
mrun
MR1="$MRC:$MREN"
check "install migration: exit 0 and the Renamed line once; settings.mode, role modes and prompt key renamed, phase kept" "$MR1:$(jq -c '[.settings.mode, .settings.phase, .roles.zeta.modes, (.roles.zeta.prompt | keys)]' "$MK/config.json")" '0:1:["academic-research","writing",["academic-research","programmer"],["academic-research","programmer"]]'
check "install migration: prompt paths in the four prefix forms are rewritten, only that segment" "$(jq -r '[.roles.zeta.prompt["academic-research"], .roles.k1.prompt, .roles.k2.prompt, .roles.k3.prompt] | join(" ")' "$MK/config.json")" "{kit}/roles/academic-research/z.md $MK/roles/academic-research/a.md ~/.orca-roles/prompts/academic-research/b.md {home}/.orca-roles/roles/academic-research/sub/c.md"
# shellcheck disable=SC2088
check "install migration: paths outside the kit or not at the folder boundary are untouched, role order kept" "$(jq -r '[.roles.k4.prompt, .roles.k5.prompt, .roles.k6.prompt, .roles.k7.prompt] | join(" ")' "$MK/config.json"):$(jq -r '.roles | keys_unsorted | .[0:3] | join(",")' "$MK/config.json")" "~/notes/roles/academic-writer/x.md {kit}/roles/academic-writer-extra/x.md {kit}/roles/foo/roles/academic-writer/x.md /data/prompts/academic-writer/x.md:zeta,k1,k2"
check "install migration: the user's roles move (hidden and nested included), the old path is a relative link, Moved line once" "$MMOV:$(readlink "$MK/roles/academic-writer"):$(cat "$MK/roles/academic-research/a.md" "$MK/roles/academic-research/.hid" "$MK/roles/academic-research/sub/c.md" | tr '\n' ' '):$(cat "$MK/roles/academic-writer/a.md")" "1:academic-research:A H C :A"
check "install migration: prompts/academic-writer is a relative link to prompts/academic-research and resolves" "$(readlink "$MK/prompts/academic-writer"):$(cmp -s "$MK/prompts/academic-writer/planner.md" "$ROOT/prompts/academic-research/planner.md" && echo same)" "academic-research:same"
S1="$(mstate)"; mrun
check "install migration: a second install prints none of the migration lines and changes nothing" "$MRC:$MREN:$MMOV:$MWARN:$([ "$(mstate)" = "$S1" ] && echo same)" "0:0:0:0:same"
# a conflict keeps both, warns per entry, leaves the old folder without a link; once merged by hand the next install links it
rm -rf "$MK/roles"; mkdir -p "$MK/roles/academic-writer" "$MK/roles/academic-research"; echo OLD > "$MK/roles/academic-writer/a.md"; echo NEW > "$MK/roles/academic-research/a.md"; echo B > "$MK/roles/academic-writer/b.md"; echo OLD2 > "$MK/roles/academic-writer/.h"; echo NEW2 > "$MK/roles/academic-research/.h"
mrun
check "install migration conflict: both versions kept, one WARNING per kept entry naming both paths, Moved for the rest, no link" "$MMOV:$MWARN:$(cat "$MK/roles/academic-writer/a.md" "$MK/roles/academic-research/a.md" "$MK/roles/academic-writer/.h" "$MK/roles/academic-research/.h" | tr '\n' ' '):$(cat "$MK/roles/academic-research/b.md"):$([ -L "$MK/roles/academic-writer" ] && echo link || echo dir):$(ls -A "$MK/roles/academic-writer" | tr '\n' ' '):$(printf '%s\n' "$MOUT" | grep -c "^WARNING: $MK/roles/academic-writer/a.md was not moved: $MK/roles/academic-research/a.md already exists. Any prompt path in your configuration that named the old file now names the new one. Merge them by hand, then run install.sh again.$")" "1:2:OLD NEW OLD2 NEW2 :B:dir:.h a.md :1"
rm -f "$MK/roles/academic-writer/a.md" "$MK/roles/academic-writer/.h"; mrun
check "install migration conflict: after the manual merge the next install links the old path, no warning" "$MRC:$MWARN:$(readlink "$MK/roles/academic-writer")" "0:0:academic-research"
# a link to somewhere else is replaced, a user without the old mode sees no change and no new output
rm -rf "$MK/roles"; mkdir -p "$MK/roles/elsewhere"; ln -s elsewhere "$MK/roles/academic-writer"; mrun
check "install migration: an old link pointing elsewhere is replaced by the right one, the folder it pointed to is untouched" "$(readlink "$MK/roles/academic-writer"):$([ -d "$MK/roles/elsewhere" ] && echo kept)" "academic-research:kept"
rm -rf "$MK/roles"; cat > "$MK/config.json" <<J
{ "settings": { "mode": "programmer" }, "roles": { "foo": { "title": "Foo", "prompt": "{kit}/roles/foo.md" }, "k": { "title": "K", "prompt": "~/notes/roles/academic-writer/x.md" } } }
J
mrun; B1="$(shasum < "$MK/config.json")"; mrun
check "install migration: without the old mode nothing is printed, no roles folder or link appears, config stable" "$MRC:$MREN:$MMOV:$MWARN:$([ -e "$MK/roles/academic-writer" ] || [ -L "$MK/roles/academic-writer" ] || [ -e "$MK/roles/academic-research" ] && echo present || echo none):$([ "$(shasum < "$MK/config.json")" = "$B1" ] && echo same):$(jq -r '.roles.foo.prompt, .roles.k.prompt' "$MK/config.json" | tr '\n' ' ')" "0:0:0:0:none:same:{kit}/roles/foo.md ~/notes/roles/academic-writer/x.md "
}

sec_install() {
# install.sh records what it installed (VERSION, .installed, .manifest) and saves local edits before replacing them
VH="$TMP/ver-home"; VK="$VH/.orca-roles"; rm -rf "$VH"; mkdir -p "$VH"
vrun() { if VOUT="$(cd "$TMP" && HOME="$VH" bash "$ROOT/install.sh" </dev/null 2>&1)"; then VRC=0; else VRC=$?; fi; }
vwarn() { printf '%s\n' "$VOUT" | grep -c '^WARNING: these files' || true; }
vrun
check "install: exit 0, VERSION copied, .installed starts with local@, .manifest written" "$VRC:$(cat "$VK/VERSION"):$(head -c 6 "$VK/.installed"):$([ -s "$VK/.manifest" ] && echo manifest)" "0:$(cat "$ROOT/VERSION"):local@:manifest"
check "install: the manifest lists the kit's files with relative sorted paths" "$(grep -c '  bin/launch.sh$' "$VK/.manifest"):$(grep -c '  prompts/programmer/planner.md$' "$VK/.manifest"):$(grep -c ' /' "$VK/.manifest" || true):$(sed 's/^[0-9a-f]*  //' "$VK/.manifest" | LC_ALL=C sort -c && echo sorted)" "1:1:0:sorted"
if git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
  check "install: a local clone records the commit (and -dirty when the tree has changes)" "$(sed 's/^[^ ]* //' "$VK/.installed" | sed 's/-dirty$//')" "$(git -C "$ROOT" rev-parse HEAD)"
fi
vrun
check "install: a second install with no edits prints no WARNING and creates no backup" "$VRC:$(vwarn):$([ -e "$VK/backup" ] && echo backup || echo none)" "0:0:none"
# edit a prompt, add a file under bin/, delete another: edited and added are saved and warned; the deleted one is ignored
echo "# my edit" >> "$VK/prompts/programmer/dev.md"; echo "echo mine" > "$VK/bin/mine.sh"; rm -f "$VK/prompts/programmer/tester.md"
vrun; BKD="$(find "$VK/backup" -mindepth 1 -maxdepth 1 -type d | head -1)"
check "install: edits and additions are named in one WARNING with the backup folder" "$VRC:$(vwarn):$(printf '%s\n' "$VOUT" | grep -c '^  prompts/programmer/dev.md$'):$(printf '%s\n' "$VOUT" | grep -c '^  bin/mine.sh$'):$(printf '%s\n' "$VOUT" | grep -c '^  prompts/programmer/tester.md$' || true):$(printf '%s\n' "$VOUT" | grep -c "Your copies are in $BKD")" "0:1:1:1:0:1"
check "install: the backup keeps both files at their relative path with the edited content" "$(basename "$BKD" | grep -c '^[0-9]\{8\}T[0-9]\{6\}Z$'):$(tail -1 "$BKD/prompts/programmer/dev.md"):$(cat "$BKD/bin/mine.sh")" "1:# my edit:echo mine"
check "install: the kit is restored to the repo version (edit gone, added file gone, deleted file back)" "$(cmp -s "$ROOT/prompts/programmer/dev.md" "$VK/prompts/programmer/dev.md" && echo same):$([ -e "$VK/bin/mine.sh" ] && echo present || echo gone):$([ -f "$VK/prompts/programmer/tester.md" ] && echo back)" "same:gone:back"
vrun
check "install: after the restore the next install is quiet again" "$(vwarn)" "0"
# no manifest (first install or an older kit): no comparison, no warning, no backup
rm -rf "$VK/backup" "$VK/.manifest"; echo "# edit" >> "$VK/prompts/programmer/dev.md"; vrun
check "install: without a manifest nothing is compared" "$VRC:$(vwarn):$([ -e "$VK/backup" ] && echo backup || echo none):$([ -s "$VK/.manifest" ] && echo manifest)" "0:0:none:manifest"
# curl | bash: a fake curl logs its URL and serves a tarball of a copy of the repo; the script comes from stdin
DL="$TMP/dl"; rm -rf "$DL"; mkdir -p "$DL/bin" "$DL/pkg/orca-role-hook-copy" "$DL/cwd"
cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/plugin" "$ROOT/pw" "$ROOT/README.md" "$ROOT/config.default.json" "$ROOT/VERSION" "$DL/pkg/orca-role-hook-copy/"
cat > "$DL/bin/curl" <<EOS
#!/bin/sh
echo "\$*" >> "$DL/curl.log"
exec tar -czf - -C "$DL/pkg" orca-role-hook-copy
EOS
chmod +x "$DL/bin/curl"
drun() {  # drun [VAR=value]...: installs from stdin into a fresh HOME; the last curl URL and .installed are kept
  rm -rf "$DL/home" "$DL/curl.log"; mkdir -p "$DL/home"
  if DOUT="$(cd "$DL/cwd" && env HOME="$DL/home" PATH="$DL/bin:$PATH" "$@" bash < "$ROOT/install.sh" 2>&1)"; then DRC=0; else DRC=$?; fi
  DURL="$(tail -1 "$DL/curl.log" 2>/dev/null | grep -o 'https://[^ ]*')"; DINS="$(cat "$DL/home/.orca-roles/.installed" 2>/dev/null)"
}
drun ORCA_ROLES_REF=v9.9.9 ORCA_ROLES_BRANCH=other
check "install download: ORCA_ROLES_REF wins over ORCA_ROLES_BRANCH, URL has no refs/heads, .installed names source@ref" "$DRC:$DURL:$DINS:$(cat "$DL/home/.orca-roles/VERSION")" "0:https://codeload.github.com/FelipeCastano/orca-role-hook/tar.gz/v9.9.9:FelipeCastano/orca-role-hook@v9.9.9:$(cat "$ROOT/VERSION")"
drun ORCA_ROLES_BRANCH=dev-x
check "install download: ORCA_ROLES_BRANCH still works" "$DRC:$DURL:$DINS" "0:https://codeload.github.com/FelipeCastano/orca-role-hook/tar.gz/dev-x:FelipeCastano/orca-role-hook@dev-x"
drun ORCA_ROLES_REPO=acme/kit
check "install download: no ref falls back to main, ORCA_ROLES_REPO is the source" "$DRC:$DURL:$DINS" "0:https://codeload.github.com/acme/kit/tar.gz/main:acme/kit@main"
SHA40="0123456789abcdef0123456789abcdef01234567"
drun ORCA_ROLES_REF=$SHA40
check "install download: a 40-hex ref records the sha" "$DRC:$DINS" "0:FelipeCastano/orca-role-hook@$SHA40 $SHA40"
drun ORCA_ROLES_REF=0123456
check "install download: a short hex ref is not taken for a full sha" "$DRC:$DINS" "0:FelipeCastano/orca-role-hook@0123456"
}

sec_kit_path() {
# KIT: a second copy of the kit runs end to end (own scripts, own tab commands) while HOME points to another kit or to none
kp_run() { local d="$1"; shift; (cd "$d" && env "$@" 2>&1); }   # run in a folder with exactly the given environment changes
K2="$TMP/kit2"; NH="$TMP/kp-nohome"; KPB="$TMP/kpbin"; KPL="$TMP/kpproj"; KPO="$TMP/kporca.log"
rm -rf "$K2" "$NH" "$KPB" "$KPL"; mkdir -p "$K2" "$NH" "$KPB" "$KPL"; git -C "$KPL" init -q
cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$K2/"; chmod +x "$K2"/bin/*.sh
cat > "$K2/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev" } } }
J
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$KPB/claude"; chmod +x "$KPB/claude"
cat > "$KPB/orca" <<EOT
#!/bin/sh
echo "\$*" >> "$KPO"
case "\$1 \$2" in
  "terminal create") while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; echo "{\"handle\":\"h-\$t\"}";;
  "terminal show") echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
esac
exit 0
EOT
chmod +x "$KPB/orca"
# agent.sh sources and uses the kit in KIT although HOME has no ~/.orca-roles
OUT="$(cd "$TMP" && env HOME="$NH" PATH="$KPB:$PATH" KIT="$K2" ORCA_ROLES_CONFIG="$K2/config.json" "$K2/bin/agent.sh" dev 2>&1 | tr '\n' ' ')"
case "$OUT" in *"--add-dir $K2/prompts "*) echo "ok   kit-path: agent.sh runs the kit in KIT with a HOME that has no ~/.orca-roles";; *) echo "FAIL kit-path agent.sh: $OUT"; FAIL=1;; esac
# launch.sh: the tab commands carry KIT and call the kit's agent.sh
mkdir -p "$NH/.orca-roles"; : > "$KPO"
try kp_run "$KPL" HOME="$NH" PATH="$KPB:$PATH" KIT="$K2" ORCA_ROLES_KICKOFF=/usr/bin/true "$K2/bin/launch.sh"; RCK="$RC"
KPT="$(grep '^terminal create' "$KPO" | grep -- '--title Dev')"
KPY=no; case "$KPT" in (*"--command KIT=$K2 ORCA_ROLES_CONFIG="*"'$K2/bin/agent.sh' dev"*) KPY=yes;; esac
check "kit-path: launch.sh with KIT opens the tab with KIT=<path> and the kit's agent.sh" "$RCK:$KPY" "0:yes"
# launch.sh without KIT: the command is the one it always was
rm -rf "$KPL"; mkdir -p "$KPL"; git -C "$KPL" init -q; : > "$KPO"; rmdir "$NH/.orca-roles"; ln -sfn "$K2" "$NH/.orca-roles"
try kp_run "$KPL" -u KIT HOME="$NH" PATH="$KPB:$PATH" ORCA_ROLES_KICKOFF=/usr/bin/true "$NH/.orca-roles/bin/launch.sh"; RCD="$RC"
KPT="$(grep '^terminal create' "$KPO" | grep -- '--title Dev')"
KPY=no; case "$KPT" in (*"--command ORCA_ROLES_CONFIG="*"'$NH/.orca-roles/bin/agent.sh' dev"*) KPY=yes;; esac; case "$KPT" in (*KIT=*) KPY=no;; esac
check "kit-path: launch.sh without KIT keeps the tab command (no KIT=, ~/.orca-roles/bin/agent.sh)" "$RCD:$KPY" "0:yes"
# clean.sh --msg: the kit's own files, with HOME pointing nowhere near it
rm -f "$NH/.orca-roles"; printf 'DEV=t2\n' > "$TMP/kp-state.env"
try kp_run "$TMP" HOME="$NH" PATH="$KPB:$PATH" KIT="$K2" ORCA_ROLES_STATE="$TMP/kp-state.env" ORCA_ROLES_CONFIG="$K2/config.json" "$K2/bin/clean.sh" --msg dev
case "$RC:$OUT" in 0:*"$K2/prompts/"*) echo "ok   kit-path: clean.sh honours KIT";; *) echo "FAIL kit-path clean.sh: $RC $OUT"; FAIL=1;; esac
# the anchor's command names the kit only when it is not the installed one
check "kit-path: kit_env is empty for the installed kit and KIT=<path> otherwise" "[$(KIT="$HOME/.orca-roles" kit_env)][$(KIT="/x y/kit" kit_env)]" "[][KIT=/x\\ y/kit ]"
ln -sfn "$K2" "$NH/.orca-roles"
check "kit-path: kit_env is empty when KIT is the installed kit's folder reached through a link" "[$(HOME="$NH" KIT="$K2" kit_env)]" "[]"
rm -f "$NH/.orca-roles"
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
# seq number, first hint line across steps and sets, --clear-all
CQ="$TMP/cp-seq"; rm -rf "$CQ" "$TMP/cp-seq-wt"; mkdir "$CQ"; cq() { git -C "$CQ" "$@"; }
cq init -q -b main; cq config user.email t@example.com; cq config user.name tester; printf 'a\n' > "$CQ/f"; cq add -A; cq commit -q -m init
cqrun() { CPDIR="$CQ" cprun "$@"; }; cqref() { printf '%s\n' "$CPOUT" | head -1; }; cqhint() { printf '%s\n' "$CPOUT" | sed -n "${1:-2}p"; }; cqsubj() { cq log -1 --format=%s "$1"; }
cqrun a 1; QA1="$(cqref)"; QH1="$(cqhint)"
cqrun a 2; QA2="$(cqref)"
cqrun b 1; QB1="$(cqref)"; QBH="$(cqhint)"
check "checkpoint: seq is 1 + the highest seq of the worktree, across steps" "$(cqsubj "$QA1")|$(cqsubj "$QA2")|$(cqsubj "$QB1")" "checkpoint a-c1 seq 1|checkpoint a-c2 seq 2|checkpoint b-c1 seq 3"
check "checkpoint: the first hint of the first step starts from HEAD" "$QH1" "Whole step since HEAD (the first brief):  git diff HEAD $QA1"
check "checkpoint: the first hint of a later step starts from the highest-seq checkpoint of another step" "$QBH" "Whole step since $QA2 (the first brief):  git diff $QA2 $QB1"
cqrun b 2; QB2="$(cqref)"
check "checkpoint: a later round of the same step still skips its own step in the first hint" "$(cqhint):$(cqhint 3)" "Whole step since $QA2 (the first brief):  git diff $QA2 $QB2:Since the previous checkpoint:             git diff $QB1 $QB2"
cqrun a 3; QA3="$(cqref)"
check "checkpoint: a returning step starts from the other step with the highest seq" "$(cqhint)" "Whole step since $QB2 (the first brief):  git diff $QB2 $QA3"
cqrun set 1; QS1="$(cqref)"; QS1H="$(cqhint)"
cqrun set 2; QS2="$(cqref)"
check "checkpoint: step set always starts from HEAD (set 1 and 2); set 2 also prints the corrections diff" "$QS1H|$(cqhint)|$(cqhint 3)" "Whole set since the branch base (HEAD):  git diff HEAD $QS1|Whole set since the branch base (HEAD):  git diff HEAD $QS2|Since the previous checkpoint:             git diff $QS1 $QS2"
cqrun c 1; check "checkpoint: a step after the set starts from the set's last checkpoint" "$(cqhint)" "Whole step since $QS2 (the first brief):  git diff $QS2 $(cqref)"
OLDC="$(cq commit-tree "$(cq rev-parse 'HEAD^{tree}')" -p HEAD -m 'checkpoint old-c1')"; cq update-ref "${QA1%/a-c1}/old-c1" "$OLDC"
cqrun after 1; check "checkpoint: a checkpoint with no seq counts as 0 and the next seq follows the highest" "$(cqsubj "$(cqref)")" "checkpoint after-c1 seq 9"
git -C "$CQ" worktree add -q "$TMP/cp-seq-wt" -b seqwt; CPDIR="$TMP/cp-seq-wt" cprun w 1; QW="$(cqref)"
check "checkpoint: seq counts per worktree" "$(cqsubj "$QW")" "checkpoint w-c1 seq 1"
CQS="$(cq rev-parse HEAD) $(cq status --porcelain | shasum)"
cqrun --list; NMINE="$(printf '%s\n' "$CPOUT" | grep -c '^refs/')"
cqrun --clear-all x; XRC="$CPRC"; cqrun --list
check "checkpoint: --clear-all with an argument is refused and deletes nothing" "$([ "$XRC" != 0 ] && echo fail):$(printf '%s\n' "$CPOUT" | grep -c '^refs/')" "fail:$NMINE"
cqrun --clear-all; CLR="$CPRC:$CPOUT"; cqrun --list
check "checkpoint: --clear-all deletes every checkpoint of this worktree and reports the count" "$CLR:$(printf '%s\n' "$CPOUT" | grep -c '^refs/')" "0:Deleted 10 checkpoint(s):0"
check "checkpoint: --clear-all keeps the other worktree's refs and leaves HEAD and the tree alone" "$(cq for-each-ref refs/orca-roles | grep -c '/w-c1$'):$(cq rev-parse HEAD) $(cq status --porcelain | shasum)" "1:$CQS"
cqrun --clear-all; check "checkpoint: --clear-all with nothing recorded exits 0" "$CPRC:$CPOUT" "0:Deleted 0 checkpoint(s)"
cqrun a 1; check "checkpoint: after --clear-all seq restarts at 1 and the first hint falls back to HEAD" "$(cqsubj "$(cqref)")|$(cqhint)" "checkpoint a-c1 seq 1|Whole step since HEAD (the first brief):  git diff HEAD $(cqref)"
cq worktree remove --force "$TMP/cp-seq-wt"
check "defaults: maxMutants 8 and maxSelfMutants 3 in config" "$(jq -c '[.roles.auditor.params.maxMutants, .roles.tester.params.maxSelfMutants]' "$ROOT/config.default.json")" '[8,3]'
mm() { echo "$1" > "$TMP/mm-user.json"; upgrade_config "$ROOT/config.default.json" "$TMP/mm-user.json" | jq -c '[.roles.auditor.params.maxMutants, .roles.tester.params.maxSelfMutants]'; }
check "upgrade_config moves the old defaults 15/5 to 8/3" "$(mm '{"roles":{"auditor":{"params":{"maxMutants":15}},"tester":{"params":{"maxSelfMutants":5}}}}')" "[8,3]"
check "upgrade_config keeps a user's own maxMutants/maxSelfMutants" "$(mm '{"roles":{"auditor":{"params":{"maxMutants":12}},"tester":{"params":{"maxSelfMutants":4}}}}')" "[12,4]"
check "upgrade_config gives 8/3 to a config without the keys" "$(mm '{"roles":{}}')" "[8,3]"
echo "ok   checkpoint defaults"
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
    to=""; sub=""; body=""; ty=""; while [ \$# -gt 0 ]; do case "\$1" in --to) to="\$2";; --subject) sub="\$2";; --body) body="\$2";; --type) ty="\$2";; esac; shift; done
    if [ "\$ty" = status ]; then echo "HND \$to|\$ty|\$sub|\$(printf '%s' "\$body" | tr '\\n' '/')" >> "\$L"; [ -f "$MF/failhnd" ] && exit 1; exit 0; fi
    echo "ESC \$to|\$sub|\$body" >> "\$L"; [ -f "$MF/failsend" ] && exit 1;;
esac
exit 0
EOS
chmod +x "$MF/bin/orca"
CLERR="There's an issue with the selected model (x). It may not exist or you may not have access to it."
echo 0 > "$MF/waitdelay"; export ORCA_ROLES_KICK_SETTLE=0
mf() {  # <config json> <mode: bad | clean> <new roles>; env: ERRTXT ERRWRAP STALE PASTE VIEW REM FAILSEND PRE
  printf '%s' "$1" > "$MF/cfg.json"; : > "$MF/orca.log"; rm -f "$MF"/sent.* "$MF"/hist.* "$MF/paste" "$MF/wrap" "$MF/view" "$MF/gd/orca-roles.models" "$MF/gd/orca-roles.kicked" "$MF/failsend" "$MF/failhnd" "$MF/waits.log"
  printf '%s\n' "${ERRTXT:-$CLERR}" > "$MF/errtxt"; [ -z "${ERRWRAP:-}" ] || echo "$ERRWRAP" > "$MF/wrap"; [ -z "${PASTE:-}" ] || : > "$MF/paste"; [ -z "${VIEW:-}" ] || echo "$VIEW" > "$MF/view"
  [ -z "${STALE:-}" ] || for hh in hp hd ht ha; do echo "${STALETXT:-$CLERR}" > "$MF/hist.$hh"; done
  [ -z "${FAILSEND:-}" ] || : > "$MF/failsend"; [ -z "${FAILHND:-}" ] || : > "$MF/failhnd"; [ -z "${PRE:-}" ] || printf '%s' "$PRE" > "$MF/gd/orca-roles.models"; printf 'PLANNER=hp\nDEV=hd\nTESTER=ht\nAUDITOR=ha\n' > "$MF/gd/orca-roles.env"
  echo "$2" > "$MF/mode"
  (cd "$MF/wt" && HOME="$TMP/home" PATH="$MF/bin:$PATH" ORCA_TERMINAL_HANDLE="${OTH:-}" "$KIT/bin/kickoff.sh" "$MF/wt" "$MF/gd/orca-roles.env" "$MF/cfg.json" "$3" "" "${REM:-}" "${REUSED:-}" > "$MF/out.log" 2>&1)
}
mfc() { printf '{ "settings": { "kickoffTimeoutSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false }, "defaults": { "agent": "claude", "params": {} }, "mcpServers": {}, "roles": { "planner": { "title": "Planner", "model": "claude-opus-5-5" }, "dev": { %s } } }' "$1"; }
models() { cat "$MF/gd/orca-roles.models" 2>/dev/null | tr '\n' ' '; }
nomodel() { grep -c '/model' "$MF/orca.log" || true; }
hnds() { grep '^HND ' "$MF/orca.log" || true; }
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
# kickoff.sh removes only its own registry file when it ends
printf '#!/bin/sh\nmkdir -p "%s/gd/orca-roles.kickoff.d"; echo dev > "%s/gd/orca-roles.kickoff.d/$$"; echo "$$" > "%s/own.pid"\nexec "$@"\n' "$MF" "$MF" "$MF" > "$MF/regrun"; chmod +x "$MF/regrun"
printf '%s' "$(mfc "$DEVOK")" > "$MF/cfg.json"; : > "$MF/orca.log"; echo clean > "$MF/mode"; rm -rf "$MF/gd/orca-roles.kickoff.d"; mkdir -p "$MF/gd/orca-roles.kickoff.d"
sleep 30 & OP=$!; echo dev > "$MF/gd/orca-roles.kickoff.d/$OP"
(cd "$MF/wt" && HOME="$TMP/home" PATH="$MF/bin:$PATH" "$MF/regrun" "$KIT/bin/kickoff.sh" "$MF/wt" "$MF/gd/orca-roles.env" "$MF/cfg.json" "dev" "" "" "" > "$MF/out.log" 2>&1)
OWN="$(cat "$MF/own.pid")"
check "kickoff.sh: when it ends it removes its own registry file and leaves another kickoff's" "$([ -f "$MF/gd/orca-roles.kickoff.d/$OWN" ] && echo kept || echo gone):$([ -f "$MF/gd/orca-roles.kickoff.d/$OP" ] && echo kept || echo gone)" "gone:kept"
kill "$OP" 2>/dev/null; wait "$OP" 2>/dev/null || true; rm -rf "$MF/gd/orca-roles.kickoff.d"
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
check "model-check: nothing outside the git dir is written" "$(find "$MF/wt" -mindepth 1 -not -path "$MF/wt/.git" -not -path "$MF/wt/.git/*" | wc -l | tr -d ' '):$(ls "$MF/gd" | tr '\n' ' '):$(cd "$TMP/home" && find . | sort | shasum | cmp -s - <(echo "$HB") && echo same || echo changed)" "0:orca-roles.env orca-roles.kicked orca-roles.models :same"
# the live Planner is told the new handles
HB1="HND hp|status|Role handles changed|roles opened or reopened: Dev. Use these handles from now on:/PLANNER=hp/DEV=hd/TESTER=ht/AUDITOR=ha"
mf "$(mfc "$DEVOK")" clean "dev"
check "handles: one status to the live Planner with every handle" "$(hnds)" "$HB1"
check "handles: the user is told" "$(grep -c '^Told the Planner the new handles\.$' "$MF/out.log")" "1"
mf "$(mfc "$DEVOK" | jq -c '.roles.tester = {"title": "Tester", "model": "claude-opus-5-5"}')" clean "dev tester"
check "handles: two reopened workers, one message naming both" "$(hnds | wc -l | tr -d ' '):$(hnds | grep -c 'roles opened or reopened: Dev, Tester\. Use')" "1:1"
REM=dev mf "$(mfc "$DEVOK")" clean "dev"
check "handles: a remembered worker also counts" "$(hnds | wc -l | tr -d ' ')" "1"
mf "$(mfc "$DEVOK")" clean "planner"
check "handles: only the Planner reopened, no message" "$(hnds | wc -l | tr -d ' ')" "0"
mf "$(mfc "$DEVOK")" clean "planner dev"
check "handles: Planner and worker reopened, no message" "$(hnds | wc -l | tr -d ' ')" "0"
mf "$(mfc "$DEVOK")" clean ""
check "handles: nothing reopened, no message" "$(hnds | wc -l | tr -d ' ')" "0"
OTH=hp mf "$(mfc "$DEVOK")" clean "dev"
check "handles: the Planner ran it itself, no send, says so" "$(hnds | wc -l | tr -d ' '):$(grep -c '^Not telling the Planner the new handles: it ran this launch itself\.$' "$MF/out.log")" "0:1"
OTH=other mf "$(mfc "$DEVOK")" clean "dev"
check "handles: another terminal ran it, the Planner is told" "$(hnds | wc -l | tr -d ' ')" "1"
REUSED=dev OTH=other mf "$(mfc "$DEVOK")" clean "dev"
check "handles: a reused role is kicked and recorded in orca-roles.kicked but does not trigger 'Role handles changed'" "$(hnds | wc -l | tr -d ' '):$(grep -c '^SEND ' "$MF/orca.log"):$(cat "$MF/gd/orca-roles.kicked" | tr '\n' ' ')" "0:1:DEV=hd "
REUSED=dev OTH=other mf "$(mfc "$DEVOK")" clean "dev planner"
check "handles: a reused role next to a reopened Planner: both kicked, both recorded" "$(hnds | wc -l | tr -d ' '):$(grep -c '^SEND ' "$MF/orca.log"):$(sort "$MF/gd/orca-roles.kicked" | tr '\n' ' ')" "0:2:DEV=hd PLANNER=hp "
FAILHND=1 mf "$(mfc "$DEVOK")" clean "dev"
check "handles: a failed send is reported with the cat hint" "$(grep -c "^Could not tell the Planner the new handles; tell it to run: cat $MF/gd/orca-roles.env\$" "$MF/out.log")" "1"
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
echo "ok   model-check: config"
unset ORCA_ROLES_KICK_SETTLE
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
[ -f "$MM/codex.bigerr" ] && head -c 300000 /dev/zero | tr '\0' x >&2
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
touch "$MM/codex.bigerr"; mt cx --check; check "models: codex --check: a match in the output is found even when stderr is large (no SIGPIPE)" "$(tabs | cut -d';' -f2)" "gpt-c|unavailable"; rm -f "$MM/codex.bigerr"
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
# --model: exactly one candidate, with and without --check
mt cl --model opus; check "models: --model alone prints just that one" "$RC:$(tabs)" "0:opus"
mt cl --model sonnet --check; check "models: --model with --check probes only that one (deduplicated)" "$RC:$(tabs)" "0:sonnet|ok|claude-opus-5-5"
echo 404 > "$MM/b.zzz"; mt cl --check --model zzz; check "models: --model with --check reports unavailable" "$RC:$(tabs)" "0:zzz|unavailable"; rm -f "$MM/b.zzz"
rm -f "$MM/codex.env"; mt cx --model gpt-c --check; check "models: --model on a codex role skips the listing" "$(tabs):$([ -f "$MM/codex.env" ] && echo listed || echo skipped)" "gpt-c|unavailable:skipped"
mt cl --model; check "models: --model needs a value" "$RC" "1"
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
unset MM
}

sec_review_skill() {
# review-skill.sh: a fake claude on PATH (never the real one) that records its argv and serves plugin list / marketplace add / install
RS="$TMP/rskill"; rm -rf "${RS:?}"; mkdir -p "$RS/bin" "$RS/nobin" "$RS/tmp" "$RS/plug/skills/lens-review"
echo "skill" > "$RS/plug/skills/lens-review/SKILL.md"
for t in bash jq git pgrep mktemp sed head tr cat grep sleep rm awk uname dirname env kill; do ln -sf "$(command -v $t)" "$RS/nobin/$t"; done
cat > "$RS/bin/claude" <<'EOS'
#!/bin/bash
echo "$*" >> "$RS/argv.log"
rd() { cat "$RS/$1" 2>/dev/null || echo ok; }
case "$1 $2" in
  "plugin list")
    case "$(rd list.mode)" in
      ok) cat "$RS/list.json";;
      garbage) echo "not json";;
      fail) echo "list boom" >&2; echo second >&2; exit 5;;
      hang) echo $$ > "$RS/hang.pid"; exec sleep 30;;
      tree) sleep 30 & echo $! > "$RS/child.pid"; wait;;
    esac;;
  "plugin marketplace")
    case "$(rd mkt.mode)" in
      ok) echo "added";;
      exists) echo "Marketplace 'lens-review' already exists" >&2; exit 1;;
      upper) cat "$RS/mkt.msg" >&2; exit 1;;
      fail) echo "mkt boom: no network" >&2; exit 1;;
      hang) echo $$ > "$RS/hang.pid"; exec sleep 30;;
    esac;;
  "plugin install")
    case "$(rd inst.mode)" in
      ok) cp "$RS/installed.json" "$RS/list.json"; echo "installed";;
      fail) echo "install boom" >&2; exit 1;;
      hang) echo $$ > "$RS/hang.pid"; exec sleep 30;;
    esac;;
esac
EOS
chmod +x "$RS/bin/claude"
mkdir -p "$RS/wt"; git -C "$RS/wt" init -q; git -C "$RS/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
jq -n --arg p "$RS/plug" '[{id:"other@x",version:"1",enabled:true,installPath:"/nowhere"},{id:"lens-review@lens-review",version:"1.2.3",scope:"user",enabled:true,installPath:$p}]' > "$RS/installed.json"
jq '.[1].enabled = false' "$RS/installed.json" > "$RS/disabled.json"
echo '[{"id":"other@x","version":"1","enabled":true,"installPath":"/nowhere"}]' > "$RS/missing.json"
RSC="$RS/config.json"; merged_config . > "$RSC"
rs_state() { cp "$RS/$1.json" "$RS/list.json"; rm -f "${RS:?}"/*.mode "$RS/argv.log" "$RS/hang.pid"; }
export RS
rs_run() { (cd "$RS/wt" && env PATH="$RS/bin:$PATH" TMPDIR="$RS/tmp" ORCA_ROLES_CONFIG="${RSCFG:-$RSC}" env KIT="$KIT" "$KIT/bin/review-skill.sh" "$@" 2>"$RS/err"); }
rs_try() { if OUT="$(rs_run "$@")"; then RC=0; else RC=$?; fi; ERR="$(cat "$RS/err")"; }
rs_calls() { tr '\n' ';' < "$RS/argv.log" 2>/dev/null; }
check "review-skill: the default configuration names the plugin" "$(jq -r '.settings.prReviewer | [.marketplace, .plugin, .skill] | join(" ")' "$KIT/config.default.json")" "romerox3/lens-review lens-review@lens-review skills/lens-review/SKILL.md"
check "review-skill: -h prints the header and exits 0" "$(env KIT="$KIT" "$KIT/bin/review-skill.sh" -h | head -1 | cut -c1-31):$?" "# Finds and installs the review:0"
try env KIT="$KIT" "$KIT/bin/review-skill.sh" bogus 2>/dev/null; check "review-skill: an unknown command exits 1" "$RC" "1"
try env KIT="$KIT" "$KIT/bin/review-skill.sh" 2>/dev/null; check "review-skill: no command exits 1" "$RC" "1"
rs_state installed; rs_try status
check "review-skill: status installed" "$RC:$OUT" "0:installed 1.2.3 $RS/plug"
rs_state disabled; rs_try status; check "review-skill: status disabled" "$RC:$OUT" "3:disabled 1.2.3 $RS/plug"
rs_state missing; rs_try status; check "review-skill: status missing" "$RC:$OUT" "2:missing"
rs_state installed; echo garbage > "$RS/list.mode"; rs_try status; check "review-skill: status with non-JSON output" "$RC:$OUT:$ERR" "1::error claude plugin list did not print a JSON list"
echo fail > "$RS/list.mode"; rs_try status; check "review-skill: status with a failing claude shows the first stderr line" "$RC:$OUT:$ERR" "1::error list boom"
echo '{"a":1}' > "$RS/list.json"; rm -f "$RS/list.mode"; rs_try status; check "review-skill: status with JSON that is not a list" "$RC:$ERR" "1:error claude plugin list did not print a JSON list"
jq '.[1].installPath = ""' "$RS/installed.json" > "$RS/list.json"; rs_try status; check "review-skill: an entry without installPath is not installed" "$RC:$OUT" "2:missing"
(cd "$RS/wt" && PATH="$RS/nobin" ORCA_ROLES_CONFIG="$RSC" env KIT="$KIT" "$KIT/bin/review-skill.sh" status 2>"$RS/err") > "$RS/out" && RC=0 || RC=$?
check "review-skill: status without claude on PATH" "$RC:$(cat "$RS/out"):$(cat "$RS/err")" "1::error claude not found"
rs_state installed; rs_try path; check "review-skill: path prints installPath/skill" "$RC:$OUT" "0:$RS/plug/skills/lens-review/SKILL.md"
rm -f "$RS/plug/skills/lens-review/SKILL.md"; rs_try path; check "review-skill: path with the skill file missing" "$RC:$OUT:$ERR" "4::skill file not found: $RS/plug/skills/lens-review/SKILL.md"
echo "skill" > "$RS/plug/skills/lens-review/SKILL.md"
rs_state disabled; rs_try path; check "review-skill: path when disabled" "$RC:$OUT:$ERR" "3::disabled 1.2.3 $RS/plug"
rs_state missing; rs_try path; check "review-skill: path when missing" "$RC:$OUT:$ERR" "2::missing"
echo garbage > "$RS/list.mode"; rs_try path; check "review-skill: path when claude fails" "$RC:$OUT" "1:"
rs_state installed; rs_try root; check "review-skill: root installed prints the parent of installPath" "$RC:$OUT" "0:$RS"
rs_state missing; rs_try root; check "review-skill: root missing" "$RC:$OUT:$ERR" "2::missing"
rs_state disabled; rs_try root; check "review-skill: root disabled" "$RC:$OUT:$ERR" "3::disabled 1.2.3 $RS/plug"
rs_state installed; rs_try install
check "review-skill: install when already installed does nothing else" "$RC:$(printf '%s' "$OUT" | tr '\n' '|'):$(rs_calls)" "0:already installed|$RS/plug/skills/lens-review/SKILL.md:plugin list --json;"
rs_state missing; rs_try install
check "review-skill: install from missing adds the marketplace, installs, then prints the path" "$RC:$OUT:$(rs_calls)" "0:$RS/plug/skills/lens-review/SKILL.md:plugin list --json;plugin marketplace add romerox3/lens-review;plugin install lens-review@lens-review;plugin list --json;"
rs_state missing; echo exists > "$RS/mkt.mode"; rs_try install
check "review-skill: a marketplace that already exists is tolerated" "$RC:$OUT:$ERR:$(rs_calls | grep -o 'plugin install')" "0:$RS/plug/skills/lens-review/SKILL.md::plugin install"
rs_state missing; echo fail > "$RS/mkt.mode"; rs_try install
check "review-skill: marketplace failure shows its output, exit 1, no install" "$RC:$ERR:$(rs_calls | grep -c 'plugin install')" "1:mkt boom: no network:0"
rs_state missing; echo fail > "$RS/inst.mode"; rs_try install
check "review-skill: install failure shows its output, exit 1" "$RC:$ERR" "1:install boom"
rs_state disabled; rs_try install
check "review-skill: install on a disabled plugin refuses with exit 3 and calls nothing but plugin list" "$RC:$OUT:$ERR:$(rs_calls)" "3::disabled 1.2.3 $RS/plug
the plugin is disabled: enable it with claude plugin enable lens-review@lens-review (install would re-enable it):plugin list --json;"
rs_state missing; cp "$RS/installed.json" "$RS/real.json"; echo '[]' > "$RS/installed.json"; rs_try install
check "review-skill: install that leaves the plugin absent fails as path does" "$RC:$OUT:$ERR" "2::missing"
cp "$RS/real.json" "$RS/installed.json"
rs_state installed; mv "$RS/plug/skills" "$RS/skills.bak"; rs_try install
check "review-skill: install with the skill file missing exits 4" "$RC:$ERR" "4:skill file not found: $RS/plug/skills/lens-review/SKILL.md"
mv "$RS/skills.bak" "$RS/plug/skills"
# a hung claude is killed after the bound, nothing is left running
for mode in list mkt; do
  rs_state missing; if [ "$mode" = mkt ]; then echo hang > "$RS/mkt.mode"; else echo hang > "$RS/list.mode"; fi
  T0=$SECONDS; if OUT="$(cd "$RS/wt" && env PATH="$RS/bin:$PATH" TMPDIR="$RS/tmp" ORCA_ROLES_CONFIG="$RSC" ORCA_ROLES_SKILL_TIMEOUT=1 env KIT="$KIT" "$KIT/bin/review-skill.sh" install 2>"$RS/err")"; then RC=0; else RC=$?; fi
  HP="$(cat "$RS/hang.pid" 2>/dev/null)"; sleep 0.3
  check "review-skill: a hung claude ($mode) is cut after the bound: exit 1, message, process gone, quick" "$RC:$(cat "$RS/err"):$([ -n "$HP" ] && kill -0 "$HP" 2>/dev/null && echo alive || echo gone):$([ $((SECONDS - T0)) -lt 8 ] && echo quick)" "1:error claude timed out:gone:quick"
done
rs_state missing; echo hang > "$RS/inst.mode"; rm -f "$RS/hang.pid"
if OUT="$(cd "$RS/wt" && env PATH="$RS/bin:$PATH" TMPDIR="$RS/tmp" ORCA_ROLES_CONFIG="$RSC" ORCA_ROLES_SKILL_TIMEOUT=1 env KIT="$KIT" "$KIT/bin/review-skill.sh" install 2>"$RS/err")"; then RC=0; else RC=$?; fi
HP="$(cat "$RS/hang.pid" 2>/dev/null)"; sleep 0.3
check "review-skill: a hung plugin install is cut after the bound: exit 1, message, process gone" "$RC:$(cat "$RS/err"):$([ -n "$HP" ] && kill -0 "$HP" 2>/dev/null && echo alive || echo gone)" "1:error claude timed out:gone"
rs_state installed; echo tree > "$RS/list.mode"; rm -f "$RS/child.pid"
if OUT="$(cd "$RS/wt" && env PATH="$RS/bin:$PATH" TMPDIR="$RS/tmp" ORCA_ROLES_CONFIG="$RSC" ORCA_ROLES_SKILL_TIMEOUT=1 env KIT="$KIT" "$KIT/bin/review-skill.sh" status 2>"$RS/err")"; then RC=0; else RC=$?; fi
CP="$(cat "$RS/child.pid" 2>/dev/null)"; sleep 0.3
check "review-skill: a hung claude's child process is killed with it" "$RC:$(cat "$RS/err"):$([ -n "$CP" ] && kill -0 "$CP" 2>/dev/null && echo alive || echo gone)" "1:error claude timed out:gone"
rs_state missing; echo fail > "$RS/list.mode"; rs_try install
check "review-skill: install with a failing plugin list runs no marketplace add or install" "$RC:$ERR:$(rs_calls)" "1:error list boom:plugin list --json;"
rs_state missing; echo ALREADY EXISTS > "$RS/mkt.msg"; echo upper > "$RS/mkt.mode"; rs_try install
check "review-skill: 'already exists' is matched case-insensitively" "$RC:$(rs_calls | grep -c 'plugin install')" "0:1"
jq '. + [(.[1] | .enabled = false | .version = "0.0.1" | .installPath = "/old")]' "$RS/installed.json" > "$RS/list.json"; jq 'reverse' "$RS/list.json" > "$RS/list2.json"; cp "$RS/list2.json" "$RS/list.json"; rm -f "$RS/list.mode"; rs_try status
check "review-skill: with several entries for the id the enabled one wins" "$RC:$OUT" "0:installed 1.2.3 $RS/plug"
check "review-skill: no temp folder left behind" "$(ls "$RS/tmp" | wc -l | tr -d ' ')" "0"
# settings.prReviewer overrides
jq '.settings.prReviewer = {marketplace: "me/mkt", plugin: "mine@mkt", skill: "a/B.md"}' "$RSC" > "$RS/cfg2.json"; mkdir -p "$RS/plug/a"; echo b > "$RS/plug/a/B.md"
rs_state installed; jq '.[1].id = "mine@mkt"' "$RS/installed.json" > "$RS/mine.json"; cp "$RS/mine.json" "$RS/list.json"
RSCFG="$RS/cfg2.json" rs_try path; check "review-skill: another plugin id and skill path are honoured" "$RC:$OUT" "0:$RS/plug/a/B.md"
RSCFG="$RS/cfg2.json" rs_try status; check "review-skill: status uses the configured plugin" "$RC:$OUT" "0:installed 1.2.3 $RS/plug"
rs_state missing; RSCFG="$RS/cfg2.json" rs_try install; check "review-skill: install with another plugin adds its marketplace and installs it" "$RC:$(grep -v 'plugin list' "$RS/argv.log" | tr '\n' ';')" "2:plugin marketplace add me/mkt;plugin install mine@mkt;"
rs_state installed; RSCFG="$RS/none.json" rs_try status; check "review-skill: without a saved configuration it uses the merged one" "$RC:$OUT" "0:installed 1.2.3 $RS/plug"
jq 'del(.settings.prReviewer)' "$RSC" > "$RS/cfg3.json"; RSCFG="$RS/cfg3.json" rs_try status; check "review-skill: a configuration without prReviewer falls back to the default" "$RC" "0"
# without ORCA_ROLES_CONFIG: the worktree's saved <gitdir>/orca-roles.config.json is the configuration (what the Planner really uses)
RSG="$(cd "$RS/wt" && cd "$(git rev-parse --git-dir)" && pwd)"; cp "$RS/mine.json" "$RS/list.json"
rs_dflt() { OUT="$(cd "$RS/wt" && env -u ORCA_ROLES_CONFIG PATH="$RS/bin:$PATH" TMPDIR="$RS/tmp" env KIT="$KIT" "$KIT/bin/review-skill.sh" "$@" 2>"$RS/err")" && RC=0 || RC=$?; }
cp "$RS/cfg2.json" "$RSG/orca-roles.config.json"; rs_dflt path; D1="$RC:$OUT"
rm -f "$RSG/orca-roles.config.json"; rs_dflt path; D2="$RC:$OUT:$(cat "$RS/err")"
check "review-skill: without ORCA_ROLES_CONFIG the saved <gitdir>/orca-roles.config.json supplies prReviewer (a custom skill path), and without it the default applies" "$D1|$D2" "0:$RS/plug/a/B.md|2::missing"
# check_config and upgrade_config
chk() { jq --argjson v "$1" '.settings.prReviewer = $v' "$KIT/config.default.json" > "$RS/chk.json"; check_config "$RS/chk.json"; }
MSG="ERROR: invalid configuration: settings.prReviewer must be {marketplace, plugin, skill}"
check "review-skill: check_config accepts the default" "$(check_config "$KIT/config.default.json")" ""
for bad in '"x"' 'null' '[]' '{}' '{"marketplace":"a","plugin":"b"}' '{"marketplace":"a","plugin":"b","skill":""}' '{"marketplace":1,"plugin":"b","skill":"c"}'; do
  check "review-skill: check_config rejects $bad" "$(chk "$bad")" "$MSG"
done
echo '{"settings":{"language":"es"},"roles":{}}' > "$RS/old.json"
check "review-skill: upgrade_config adds prReviewer to an old configuration" "$(upgrade_config "$KIT/config.default.json" "$RS/old.json" | jq -r '.settings.prReviewer.plugin + " " + .settings.language')" "lens-review@lens-review es"
check "review-skill: nothing is written in the worktree" "$(git -C "$RS/wt" status --porcelain | wc -l | tr -d ' ')" "0"
unset RS
}

sec_relaunch() {
# relaunch-role.sh with a fake orca, claude and kickoff, in an own kit (never the clone)
pk_setup
cat > "$PK/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner" }, "dev": { "title": "Dev", "model": "m-dev" }, "deployer": { "title": "Deployer" } } }
J
RW="$TMP/rlproj"; mkdir -p "$RW" "$TMP/rlbin"; git -C "$RW" init -q; RG="$RW/.git"
RLOG="$TMP/rlorca.log"; RKL="$TMP/rlkick.log"; RCL="$TMP/rlclaude.log"; : > "$RLOG"; : > "$RKL"; : > "$RCL"
cat > "$TMP/rlbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$RLOG"
case "\$1 \$2" in
  "terminal create") [ -f "$TMP/rl-failcreate" ] && exit 1
    while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; echo "{\"handle\":\"h-\$t-\$(grep -c '^terminal create' "$RLOG")\"}";;
  "terminal close") [ -f "$TMP/rl-failclose" ] && exit 1;;
  "terminal show") [ -f "$TMP/r-alive" ] && { echo '{"agentIdentity":"claude"}'; exit 0; }; echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
esac
exit 0
EOS
cat > "$TMP/rlbin/claude" <<EOS
#!/bin/bash
m=""; pv=""; for x in "\$@"; do [ "\$pv" = --model ] && m="\$x"; pv="\$x"; done
echo "\$m" >> "$RCL"
case "\$m" in
  gone) echo '{"api_error_status":404,"result":"nope"}'; exit 1;;
  net) echo "boom: no network" >&2; exit 1;;
  *) echo '{"result":"ok","modelUsage":{"claude-x":{}}}';;
esac
EOS
printf '#!/bin/sh\necho "$4" >> "%s"\ncp "$2" "$(dirname "$2")/orca-roles.kicked"\n' "$RKL" > "$TMP/rlbin/kickoff"; chmod +x "$TMP/rlbin"/*
rl() { (cd "$RW" && HOME="$PH" PATH="$TMP/rlbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/rlbin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PKL/bin/launch.sh" "$@" 2>&1); }
rr() { (cd "$RW" && HOME="$PH" PATH="$TMP/rlbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/rlbin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PKL/bin/relaunch-role.sh" "$@" 2>&1); }
rstate() { cat "$RG/orca-roles.env" "$RG/orca-roles.pty" "$RG/orca-roles.overrides.json" "$RG/orca-roles.config.json" | cksum; }
rclosed() { grep -c '^terminal close' "$RLOG" || true; }
rkicks() { sleep 1; tr -d ' ' < "$RKL" | tr '\n' ','; }
rl --only dev,planner >/dev/null; touch "$TMP/r-alive"
B="$(rstate)"
for args in "dev" "dev --model" "nobody --model good" "planner --model good" "Planner --model good" "deployer --model good" "--model good" "dev --bogus x"; do
  # shellcheck disable=SC2086
  try rr $args; check "relaunch: '$args' fails and changes nothing" "$RC:$(rclosed):$(rstate)" "1:0:$B"
done
try rr planner --model good; case "$OUT" in *"The Planner cannot be relaunched from inside the team."*) echo "ok   relaunch: planner message";; *) echo "FAIL relaunch planner: $OUT"; FAIL=1;; esac
try rr deployer --model good; case "$OUT" in *"deployer is not open in this worktree; run roles."*) echo "ok   relaunch: not open message";; *) echo "FAIL relaunch not open: $OUT"; FAIL=1;; esac
try rr dev --model gone; check "relaunch: unavailable model" "$RC:$(rclosed):$(rstate):$OUT" "1:0:$B:Model gone is not available for dev; nothing was changed."
try rr dev --model net; check "relaunch: unknown model" "$RC:$(rclosed):$(rstate):$OUT" "1:0:$B:Could not check model net (boom: no network); use --no-check to relaunch anyway"
: > "$RKL"; N0="$(grep -c '^terminal create' "$RLOG")"; OLDH="$(grep '^DEV=' "$RG/orca-roles.env")"
try rr dev --model good
check "relaunch: closes the tab and opens one new tab" "$RC:$(rclosed):$(( $(grep -c '^terminal create' "$RLOG") - N0 ))" "0:1:1"
check "relaunch: the old handle is gone, the printed line is the new one in orca-roles.env" "$([ "$(grep '^DEV=' "$RG/orca-roles.env")" != "$OLDH" ] && echo new):$(printf '%s\n' "$OUT" | tail -2 | head -1)" "new:$(grep '^DEV=' "$RG/orca-roles.env")"
check "relaunch: the closing message names the old handle" "$(printf '%s' "$OUT" | grep -c "tab closed (${OLDH#DEV=})")" "1"
case "$OUT" in *"Relaunched Dev on good; this worktree keeps that model (roles --reset forgets it)."*) echo "ok   relaunch: final message";; *) echo "FAIL relaunch final: $OUT"; FAIL=1;; esac
check "relaunch: the saved --only is kept, the model is saved and effective" "$(jq -c '[.only,.set]' "$RG/orca-roles.overrides.json"):$(jq -r .roles.dev.model "$RG/orca-roles.config.json"):$(cut -d= -f1 "$RG/orca-roles.env" | tr '\n' ' ')" '[["dev","planner"],[{"path":["roles","dev","model"],"value":"good"}]]:good:PLANNER DEV '
check "relaunch: kickoff for that role only" "$(rkicks)" "dev,"
: > "$RCL"; try rr Dev --model gone --no-check
check "relaunch: --no-check skips the probe, matches the title in any case" "$RC:$(wc -c < "$RCL" | tr -d ' '):$(jq -r .roles.dev.model "$RG/orca-roles.config.json")" "0:0:gone"
touch "$TMP/rl-failclose"; B="$(rstate)"; N0="$(grep -c '^terminal create' "$RLOG")"; : > "$RKL"
try rr dev --model good --no-check
check "relaunch: a failing close stops before launching; nothing created, state unchanged, no kickoff" "$RC:$(printf '%s' "$OUT" | grep -c 'Could not close the tab of Dev; nothing was relaunched.'):$(( $(grep -c '^terminal create' "$RLOG") - N0 )):$(rstate):$(rkicks)" "1:1:0:$B:"
rm -f "$TMP/rl-failclose"
touch "$TMP/rl-failcreate"; try rr dev --model good --no-check
check "relaunch: a failing launch after the close says so" "$RC:$(printf '%s' "$OUT" | grep -c 'Its tab was closed but relaunching failed; run roles to reopen it.')" "1:1"
rm -f "$TMP/rl-failcreate"
# outside a team: no saved state or configuration in this git dir
RN="$TMP/rlnone"; rm -rf "$RN"; mkdir -p "$RN"; git -C "$RN" init -q; N0="$(grep -c . "$RLOG")"
OUT="$(cd "$RN" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE HOME="$PH" PATH="$TMP/rlbin:$PATH" "$PKL/bin/relaunch-role.sh" dev --model good --no-check 2>&1)" && RC=0 || RC=$?
check "relaunch: outside a team -> exit 1 with the 'run this from the worktree' message, no Orca call at all" "$RC:$(printf '%s' "$OUT" | grep -c 'not found: run this from the worktree where the roles were opened.'):$(( $(grep -c . "$RLOG") - N0 )):$(find "$RN/.git" -maxdepth 1 -name "orca-roles*" | wc -l | tr -d " ")" "1:1:0:0"
}

sec_academic_research() {
# academic-research: phases (roles per phase, validation, planner message), the document scaffold, launch's git and phase guards, phase.sh
# Own test kit (never the clone) with a fake academic-research mode.
pk_setup
mkdir -p "$PK/prompts/academic-research"; for f in planner common-workers exp wr both nop; do echo "# $f" > "$PK/prompts/academic-research/$f.md"; done
cat > "$PK/config.json" <<'J'
{ "settings": { "kickoffTimeoutSeconds": 1, "launchWaitSeconds": 1, "closeComposerAgent": false, "jiraHandoff": false },
  "defaults": { "agent": "claude", "params": {} }, "mcpServers": {},
  "roles": { "planner": { "title": "Planner", "modes": "all", "phases": ["writing"] },
             "exp": { "title": "Exp", "modes": ["academic-research"], "phases": ["experiment"] },
             "wr": { "title": "Wr", "modes": ["academic-research"], "phases": ["writing"] },
             "both": { "title": "Both", "modes": ["academic-research"], "phases": ["experiment", "writing"] },
             "nop": { "title": "Nop", "modes": ["academic-research"] },
             "pe": { "title": "Pe", "modes": ["programmer", "pr-reviewer"], "phases": ["writing"] } } }
J
AC="$PK/config.json"
awe() { jq -c --argjson s "$2" '.settings += $s' "$AC" > "$TMP/aw-c.json"; KIT="$PK" enabled_roles "$TMP/aw-c.json" | tr '\n' ' '; }

# library: the phase filter applies only in academic-research, the planner stays, a missing phase is experiment
check "phases: phase_of, and enabled_roles by phase (planner kept despite its phases)" "$(jq -c '.settings.mode="academic-research"' "$AC" > "$TMP/aw-m.json"; KIT="$PK" phase_of "$TMP/aw-m.json"):$(awe x '{"mode":"academic-research"}'):$(awe x '{"mode":"academic-research","phase":"experiment"}'):$(awe x '{"mode":"academic-research","phase":"writing"}')" "experiment:planner exp both nop :planner exp both nop :planner wr both nop "
check "phases: ignored in programmer and pr-reviewer, even with settings.phase set" "$(awe x '{"mode":"programmer","phase":"experiment"}'):$(awe x '{"mode":"pr-reviewer","phase":"experiment"}'):$(awe x '{"phase":"writing"}')" "planner pe :planner pe :planner pe "
B="$(for v in '[]' '"writing"' '["x"]' '[1]' '{}' 'null' '["writing","Experiment"]'; do jq -c --argjson v "$v" '.roles.exp.phases=$v' "$AC" > "$TMP/aw-b.json"; KIT="$PK" check_config "$TMP/aw-b.json" | grep -cxF 'ERROR: role exp: phases must be a non-empty list of "experiment", "writing"'; done | tr '\n' ' ')"
S="$(for v in '"Writing"' '1' 'null' '""' '[]' '"experiment "'; do jq -c --argjson v "$v" '.settings.phase=$v | .settings.mode="programmer"' "$AC" > "$TMP/aw-b.json"; KIT="$PK" check_config "$TMP/aw-b.json" | grep -cxF 'ERROR: invalid configuration: settings.phase must be "experiment" or "writing"'; done | tr '\n' ' ')"
check "phases: check_config rejects bad phases and settings.phase (any mode), accepts good ones" "$B:$S:$(KIT="$PK" check_config "$AC"):$(jq -c '.settings.phase="writing"' "$AC" > "$TMP/aw-b.json"; KIT="$PK" check_config "$TMP/aw-b.json")" "1 1 1 1 1 1 1 :1 1 1 1 1 1 ::"
jq -c '.settings.mode="academic-research" | .settings.phase="writing"' "$AC" > "$TMP/aw-m.json"
printf 'PLANNER=h-P\nWR=h-W\nBOTH=h-B\nNOP=h-N\nPE=h-E\n' > "$TMP/aw-st.env"
M1="$(KIT="$PK" planner_msg "$TMP/aw-m.json" "planner wr both nop" "$TMP/aw-st.env" "" "" 0)"; M2="$(KIT="$PK" planner_msg "$AC" "planner pe" "$TMP/aw-st.env" "" "" 0)"
check "planner_msg: Phase only in academic-research, right after the mode" "$(printf '%s' "$M1" | grep -c 'Mode: academic-research\. Phase: writing\. Active roles'):$(printf '%s' "$M2" | grep -c 'Phase:')" "1:0"

# scaffold: fresh repo, then idempotent
SC="$PK/bin/academic-scaffold.sh"; SD="$TMP/aw-sc1"; mkdir -p "$SD"; git -C "$SD" init -q
DIRS="experimentation/configs experimentation/data experimentation/models experimentation/src experimentation/scripts experimentation/results experimentation/results/raw experimentation/logs article/sections article/literature article/literature/pdfs article/tables article/images article/template"
try "$SC" "$SD"; O1="$OUT"; R1="$RC"
GIK="$(cd "$SD" && find . -name .gitkeep | sort | tr '\n' ' ')"; H0="$(cd "$SD" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum | shasum)"; I0="$(git -C "$SD" ls-files | wc -l | tr -d ' '):$({ ls "$SD/.git/index" 2>/dev/null || true; } | wc -l | tr -d ' ')"
try "$SC" "$SD"
check "scaffold: fresh repo gets every folder, .gitkeep only in tracked ones, the ignore lines; second run prints nothing and changes nothing" "$R1:$(cd "$SD" && for d in $DIRS; do [ -d "$d" ] || echo "$d"; done | wc -l | tr -d ' '):$GIK:$(printf '%s\n' "$O1" | grep -c '^Created '):$(printf '%s\n' "$O1" | tail -1):$(sed -n 1p "$SD/.gitignore"):$(wc -l < "$SD/.gitignore" | tr -d ' '):$RC:[$OUT]:$([ "$(cd "$SD" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum | shasum)" = "$H0" ] && echo same):$(ls -A "$SD" | tr '\n' ' ')" "0:0:./article/images/.gitkeep ./article/literature/.gitkeep ./article/sections/.gitkeep ./article/tables/.gitkeep ./article/template/.gitkeep ./experimentation/configs/.gitkeep ./experimentation/results/.gitkeep ./experimentation/scripts/.gitkeep ./experimentation/src/.gitkeep :24:Updated .gitignore:# orca-roles academic-research:20:0:[]:same:.git .gitignore article experimentation "
GIL="$(sed -n '2,$p' "$SD/.gitignore" | tr '\n' ' ')"
check "scaffold: ignore lines are exactly the spec's, in order; git index untouched" "$GIL:$([ "$(git -C "$SD" ls-files | wc -l | tr -d ' '):$({ ls "$SD/.git/index" 2>/dev/null || true; } | wc -l | tr -d ' ')" = "$I0" ] && echo same)" 'experimentation/data/* !experimentation/data/README.md experimentation/models/* !experimentation/models/README.md experimentation/logs/ experimentation/results/raw/ article/literature/pdfs/ article/build/ *.aux *.bbl *.blg *.fdb_latexmk *.fls *.out *.synctex.gz *.toc *.lof *.lot article/**/*.log :same'

# scaffold: an existing project is never overwritten
SE="$TMP/aw-sc2"; mkdir -p "$SE/experimentation/src" "$SE/article/tables"; printf 'print(1)\n' > "$SE/experimentation/src/mine.py"; printf 'node_modules\n*.aux' > "$SE/.gitignore"
try "$SC" "$SE"; E1="$OUT"
EXP="$(printf 'node_modules\n*.aux\n\n# orca-roles academic-research\n'; sed -n '2,$p' "$SD/.gitignore" | grep -vxF '*.aux')"
check "scaffold: existing folders keep their content and get no .gitkeep; a .gitignore without final newline keeps its lines, gets header and only the missing lines" "$(ls -A "$SE/experimentation/src"):$(ls -A "$SE/article/tables"):$(cat "$SE/experimentation/src/mine.py"):$([ "$(cat "$SE/.gitignore")" = "$EXP" ] && echo exact):$(printf '%s\n' "$E1" | grep -c 'Created experimentation/src$\|Created article/tables$'):$(printf '%s\n' "$E1" | tail -1)" "mine.py::print(1):exact:0:Updated .gitignore"
printf 'extra\n' >> "$SE/.gitignore"; try "$SC" "$SE"
SF="$TMP/aw-sc3"; mkdir -p "$SF"; printf '# orca-roles academic-research\nmy\n' > "$SF/.gitignore"; try "$SC" "$SF"
check "scaffold: header not duplicated (existing header, rerun), no-arg and non-directory fail with a message and write nothing" "$RC:$(grep -c '^# orca-roles academic-research$' "$SE/.gitignore"):$(grep -c '^# orca-roles academic-research$' "$SF/.gitignore"):$(head -2 "$SF/.gitignore" | tr '\n' ' '):$("$SC" >/dev/null 2>&1; echo $?):$("$SC" "$TMP/aw-nonexistent" >/dev/null 2>&1; echo $?):$([ -e "$TMP/aw-nonexistent" ] && echo created)" "0:1:1:# orca-roles academic-research my :1:1:"

# launch: git is required, the phase guard, the status line
AM="$TMP/aw-proj"; mkdir -p "$AM" "$TMP/awbin" "$TMP/awnogit"; git -C "$AM" init -q -b main; AG="$AM/.git"
ALOG="$TMP/aworca.log"; : > "$ALOG"
cat > "$TMP/awbin/orca" <<EOS
#!/bin/sh
echo "\$*" >> "$ALOG"
case "\$1 \$2" in
  "terminal create") [ -f "$TMP/aw-createfail" ] && exit 1; while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done; echo "{\"handle\":\"h-\$t\"}";;
  "terminal close") [ -f "$TMP/aw-closefail" ] && exit 1; exit 0;;
  "terminal list") [ -f "$TMP/aw-listfail" ] && exit 1; [ -f "$TMP/aw-listjson" ] && cat "$TMP/aw-listjson"; exit 0;;
  "terminal show") [ -f "$TMP/aw-rt" ] && { echo '{"ok":false,"error":{"code":"runtime_unavailable"}}'; exit 1; }; [ -f "$TMP/aw-alive" ] && { echo '{"agentIdentity":"claude"}'; exit 0; }; echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 1;;
esac
exit 0
EOS
chmod +x "$TMP/awbin/orca"; printf '#!/bin/sh\nexit 0\n' > "$TMP/awbin/kickoff"; chmod +x "$TMP/awbin/kickoff"
al() { (cd "$AM" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE HOME="$PH" PATH="$TMP/awbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/awbin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PKL/bin/launch.sh" "$@" 2>&1); }
ap() { (cd "$AM" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE HOME="$PH" PATH="$TMP/awbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/awbin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PKL/bin/phase.sh" "$@" 2>&1); }
ah() { cut -d= -f1 "$AG/orca-roles.env" 2>/dev/null | tr '\n' ' '; }
astate() { echo "$(cat "$AG/orca-roles.config.json" "$AG/orca-roles.env" "$AG/orca-roles.overrides.json" 2>/dev/null | cksum)"; }
acl() { grep -c '^terminal close' "$ALOG" || true; }
(cd "$TMP/awnogit" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE GIT_CEILING_DIRECTORIES="$TMP" HOME="$PH" PATH="$TMP/awbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/awbin/kickoff" "$PKL/bin/launch.sh" --mode academic-research > "$TMP/aw-ng.out" 2>&1) && NGRC=0 || NGRC=$?
check "launch: academic-research outside a git repository fails with its message, opens and creates nothing" "$NGRC:$(grep -c 'mode academic-research needs the project to be a git repository' "$TMP/aw-ng.out"):$(grep -c '^terminal create' "$ALOG"):$(find "$TMP/awnogit" -mindepth 1 ! -name orca-roles-launch.log | wc -l | tr -d ' ')" "1:1:0:0"
try al --mode academic-research
SD1="$(ls -A "$AM" | tr '\n' ' ')"
check "launch: starts in experiment with the experiment roles only, prints Phase, runs the scaffold; --status shows Phase" "$RC:$(ah):$(printf '%s\n' "$OUT" | grep -c '^Phase: experiment$'):$SD1:$(jq -r '.settings.phase // "unset"' "$AG/orca-roles.config.json"):$(al --status | grep -c '^Phase: experiment$')" "0:PLANNER EXP BOTH NOP :1:.git .gitignore article experimentation :unset:1"
# phase guard
touch "$TMP/aw-alive"; B="$(astate)"; N="$(grep -c '^terminal create' "$ALOG" || true)"
C_PH="$(acl)"; try al --set settings.phase=writing; R_A="$RC:$(printf '%s' "$OUT" | grep -c "ERROR: this worktree's team is in phase 'experiment' and phase 'writing' was requested while Exp is still open. Change the phase with ~/.orca-roles/bin/phase.sh writing. Nothing was changed." || true):$(astate):$(grep -c '^terminal create' "$ALOG" || true)"
touch "$TMP/aw-rt"; try al --set settings.phase=writing
check "launch: a phase change when 'terminal show' gives an unknown error stops with 'Orca is not ready', nothing changed" "$RC:$(printf '%s' "$OUT" | grep -c 'ERROR: Orca is not ready (runtime_unavailable): cannot tell whether this worktree.s team is still open'):$(astate):$(grep -c '^terminal create' "$ALOG" || true):$(acl)" "1:1:$B:$N:$C_PH"
rm -f "$TMP/aw-rt"
touch "$TMP/aw-listfail"; try al --set settings.phase=writing; R_B="$RC:$(printf '%s' "$OUT" | grep -c "phase 'experiment'.*Phase 'writing' was requested; nothing was changed" || true):$(astate)"; rm -f "$TMP/aw-listfail"
check "launch: phase change under an open team of the old phase is refused (also when Orca cannot be listed), nothing changed" "$R_A:$R_B" "1:1:$B:$N:1:1:$B"
# phase.sh
try ap; R1="$RC"; try ap a b; R2="$RC"; try ap Writing; R3="$RC"; try ap ""; R4="$RC"
B="$(astate)"; try ap experiment; R5="$RC:$OUT"
(cd "$AM" && git -c user.name=t -c user.email=t@e add -A && git -c user.name=t -c user.email=t@e commit -q -m scaffold); touch "$AM/dirty.txt"
try ap writing; R6="$RC:$(printf '%s' "$OUT" | grep -c 'the repository has uncommitted changes; commit them first' || true):$(astate):$(acl)"; rm -f "$AM/dirty.txt"
check "phase.sh: bad arguments exit 1, same phase is a no-op, dirty repo refused with nothing closed or changed" "$R1$R2$R3$R4:$R5:$R6" "1111:0:Already in phase experiment.:1:1:$B:0"
# phase.sh: experiment -> writing -> experiment
git -C "$AM" status --porcelain | grep -q . && echo "FAIL academic-research: repo dirty before the switch"
N="$(grep -c '^terminal create' "$ALOG" || true)"; C0="$(acl)"
try ap writing
check "phase.sh writing: closes only the experiment role, opens the writing one, saves the phase, no 'roles would open it again' hint" "$RC:$(ah | tr ' ' '\n' | sort | tr '\n' ' '):$(acl):$(grep -c 'terminal close --terminal h-Exp ' "$ALOG"):$(( $(grep -c '^terminal create' "$ALOG") - N )):$(jq -r .settings.phase "$AG/orca-roles.config.json"):$(jq -c '.set' "$AG/orca-roles.overrides.json"):$(printf '%s' "$OUT" | grep -c 'still enabled in the configuration'):$(printf '%s\n' "$OUT" | tail -1)" "0:BOTH NOP PLANNER WR :$((C0 + 1)):1:1:writing:[{\"path\":[\"settings\",\"phase\"],\"value\":\"writing\"}]:0:Phase: writing."
B="$(astate)"; C1="$(acl)"; try ap experiment; R1="$RC:$(printf '%s' "$OUT" | grep -c 'going back to experiment needs STATE.md committed at the repository root' || true)"
printf 'state\n' > "$AM/STATE.md"; try ap experiment; R2="$RC:$(printf '%s' "$OUT" | grep -c 'uncommitted changes' || true)"
check "phase.sh experiment: refused without a committed STATE.md (absent, or untracked), nothing closed or changed" "$R1:$R2:$(astate):$(acl)" "1:1:1:1:$B:$C1"
(cd "$AM" && git -c user.name=t -c user.email=t@e add STATE.md && git -c user.name=t -c user.email=t@e commit -q -m state)
N="$(grep -c '^terminal create' "$ALOG" || true)"
try ap experiment
check "phase.sh experiment with STATE.md committed: closes the writing role, reopens the experiment one, saves the phase" "$RC:$(ah | tr ' ' '\n' | sort | tr '\n' ' '):$(acl):$(( $(grep -c '^terminal create' "$ALOG") - N )):$(jq -r .settings.phase "$AG/orca-roles.config.json"):$(printf '%s\n' "$OUT" | tail -1)" "0:BOTH EXP NOP PLANNER :$((C1 + 1)):1:experiment:Phase: experiment."
# a failing close or launch is reported and does not go on
AP2="$TMP/aw-prog"; mkdir -p "$AP2"; git -C "$AP2" init -q; (cd "$AP2" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE HOME="$PH" PATH="$TMP/awbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/awbin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PKL/bin/launch.sh" --mode programmer >/dev/null 2>&1)
try bash -c 'cd "$0" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE HOME="$1" PATH="$2" "$1/.orca-roles/bin/phase.sh" writing 2>&1' "$AP2" "$PH" "$TMP/awbin:$PATH"
PR_RC="$RC:$OUT"
# phase.sh: a failing close stops before the launch; a failing launch after the close is reported; it prints the new handles
awcfg() { jq -r '.settings.phase // "unset"' "$AG/orca-roles.config.json"; }
touch "$TMP/aw-alive" "$TMP/aw-closefail"; B="$(astate)"; N="$(grep -c '^terminal create' "$ALOG" || true)"
try ap writing
check "phase.sh: a failing close-role stops before launching; nothing created, phase and handles unchanged" "$RC:$(printf '%s' "$OUT" | grep -c 'phase.sh: could not close every role of phase experiment; run it again.'):$(( $(grep -c '^terminal create' "$ALOG") - N )):$(awcfg):$(astate)" "1:1:0:experiment:$B"
rm -f "$TMP/aw-closefail"
try ap writing
AWL="$(grep -n '^Phase: writing\.$' <<<"$OUT" | cut -d: -f1)"; AWE=""; for l in $(cat "$AG/orca-roles.env"); do AWE="$AWE$(grep -nxF "$l" <<<"$OUT" | head -1 | cut -d: -f1),"; done
check "phase.sh prints every orca-roles.env line, each before the final 'Phase: writing.' line" "$RC:$(wc -l < "$AG/orca-roles.env" | tr -d ' '):$(printf '%s' "$AWE" | tr ',' '\n' | grep -c .):$(for n in $(printf '%s' "$AWE" | tr ',' ' '); do [ "$n" -lt "$AWL" ] && echo y; done | grep -c y):$(printf '%s\n' "$OUT" | tail -1)" "0:$(wc -l < "$AG/orca-roles.env" | tr -d ' '):$(wc -l < "$AG/orca-roles.env" | tr -d ' '):$(wc -l < "$AG/orca-roles.env" | tr -d ' '):Phase: writing."
try ap experiment; touch "$TMP/aw-createfail"; N="$(grep -c '^terminal create' "$ALOG" || true)"
try ap writing
check "phase.sh: a failing launch after the close says the roles were closed, to run roles, and to rerun phase.sh only if the phase did not change; nothing after the error" "$RC:$(printf '%s' "$OUT" | grep -c 'phase.sh: the roles of phase experiment were closed but opening phase writing failed (see above); run roles to open them. If roles --status still shows phase experiment, run phase.sh writing again.'):$(printf '%s\n' "$OUT" | tail -1 | grep -c '^phase.sh: the roles of phase experiment were closed'):$(ah | grep -c EXP)" "1:1:1:0"
rm -f "$TMP/aw-createfail"; try al
# launch's phase guard: a role of the old phase whose tab is gone does not block; one Orca restored under a new handle does
rm -f "$TMP/aw-alive"; N="$(grep -c '^terminal create' "$ALOG" || true)"
try al --set settings.phase=experiment
check "launch: a phase change with the old-phase role's tab gone goes ahead and opens the new phase's role" "$RC:$(awcfg):$(tail -n +$((N + 1)) <<<"$(grep '^terminal create' "$ALOG")" | grep -c -- '--title Exp'):$(ah | grep -c EXP)" "0:experiment:1:1"
try al --set settings.phase=writing
printf 'WR=pty-wr\n' > "$AG/orca-roles.pty"; printf '{"terminals":[{"handle":"h-restored","ptyId":"pty-wr"}]}' > "$TMP/aw-listjson"; B="$(astate)"; N="$(grep -c '^terminal create' "$ALOG" || true)"
try al --set settings.phase=experiment
check "launch: a phase change is refused when the old-phase role's saved pty is a tab Orca restored; nothing changed" "$RC:$(printf '%s' "$OUT" | grep -c "phase 'writing' and phase 'experiment' was requested while Wr is still open"):$(awcfg):$(( $(grep -c '^terminal create' "$ALOG") - N )):$(astate)" "1:1:writing:0:$B"
rm -f "$TMP/aw-listjson" "$AG/orca-roles.pty"
# --reset drops the saved phase
OSAVED="$(jq -c '[.set[] | select(.path == ["settings","phase"]) | .value]' "$AG/orca-roles.overrides.json")"
try al --reset --mode academic-research
check "launch --reset: the phase saved by a switch is forgotten and the team goes back to experiment" "$OSAVED:$RC:$(printf '%s\n' "$OUT" | grep -c '^Phase: experiment$'):$(jq -c '[.set[] | select(.path == ["settings","phase"]) | .value]' "$AG/orca-roles.overrides.json"):$(awcfg)" '["writing"]:0:1:[]:unset'
touch "$TMP/aw-alive"
# close-role hint
(cd "$AM" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE HOME="$PH" PATH="$TMP/awbin:$PATH" "$PKL/bin/close-role.sh" nop 2>&1) > "$TMP/aw-h1.out"
(cd "$AM" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE HOME="$PH" PATH="$TMP/awbin:$PATH" ORCA_ROLES_PHASE_SWITCH=1 "$PKL/bin/close-role.sh" both 2>&1) > "$TMP/aw-h2.out"
check "phase.sh refuses outside academic-research; close-role.sh prints the hint except during a phase switch" "$PR_RC:$(grep -c 'still enabled in the configuration' "$TMP/aw-h1.out"):$(grep -c 'tab closed' "$TMP/aw-h2.out"):$(grep -c 'still enabled' "$TMP/aw-h2.out")" "1:phase.sh: only for mode academic-research (this worktree: programmer):1:1:0"
# the renamed mode keeps its old id as an alias: old ids in persisted state read as the new mode, with a note; the saved state moves to the new id only when a launch succeeds
LC="$TMP/aw-lc"; mkdir -p "$LC"
jq -c '.settings.mode="academic-writer" | .roles.exp.modes=["academic-writer"] | .roles.wr.prompt={"academic-writer":"/old/wr.md"} | .roles.both.prompt={"academic-writer":"/old/both.md","academic-research":"/new/both.md"}' "$AC" > "$LC/old.json"
jq -c '.roles.exp.modes=["academic-wirter"]' "$AC" > "$LC/typo.json"
mkdir -p "$LC/proj"; git -C "$LC/proj" init -q; printf '%s' '{"settings":{"mode":"academic-writer"},"roles":{"both":{"modes":["academic-writer","programmer"],"prompt":{"academic-writer":"/old/both.md","academic-research":"/new/both.md"}},"wr":{"prompt":{"academic-writer":"/old/wr.md"}}}}' > "$LC/proj/.orca-roles.json"
LM="$(cd "$LC/proj" && KIT="$PK" merged_config . | jq -c '[.settings.mode, .roles.both.modes, .roles.both.prompt, .roles.wr.prompt]')"
check "legacy id: a config saved under the old mode id reads as academic-research (mode, roles, prompt keys; merged with a project config the new key wins) and the library accepts it; a typo is still rejected" "$(KIT="$PK" mode_of "$LC/old.json"):$(KIT="$PK" enabled_roles "$LC/old.json" | tr '\n' ' '):$(KIT="$PK" prompt_of "$LC/old.json" wr):$(KIT="$PK" prompt_of "$LC/old.json" both):[$(KIT="$PK" check_config "$LC/old.json")]:$(KIT="$PK" check_config "$LC/typo.json" | grep -c 'unknown mode ids'):$(canon_mode academic-writer)|$(canon_mode Academic-Writer)|$(canon_mode academic-research):$LM" "academic-research:planner exp both nop :/old/wr.md:/new/both.md:[]:1:academic-research|Academic-Writer|academic-research:[\"academic-research\",[\"academic-research\",\"programmer\"],{\"academic-research\":\"/new/both.md\"},{\"academic-research\":\"/old/wr.md\"}]"
LY=""; i=0; for j in '{"settings":{"mode":"academic-writer"}}' '{"roles":{"x":{"modes":["programmer","academic-writer"]}}}' '{"roles":{"x":{"prompt":{"academic-writer":"p"}}}}' '{"mode":"academic-writer"}' '{"set":[{"path":["settings","mode"],"value":"academic-writer"}]}' '{"settings":{"mode":"academic-research"},"roles":{"x":{"modes":["academic-research"],"prompt":{"academic-research":"p"}}},"mode":"pr-reviewer","set":[{"path":["roles","x","model"],"value":"academic-writer"}]}' '{"roles":{"x":{"modes":"all"}}}' garbage; do
  i=$((i + 1)); printf '%s' "$j" > "$LC/ly$i.json"; if legacy_mode_in "$LC/ly$i.json"; then LY="${LY}y"; else LY="${LY}n"; fi
done
if legacy_mode_in "$LC/missing.json"; then LY="${LY}y"; else LY="${LY}n"; fi
check "legacy id: legacy_mode_in finds the old id in settings.mode, a role's modes, a prompt key, .mode and a settings.mode entry of .set, and nothing else (missing or invalid file: no)" "$LY" "yyyyynnnn"
printf '%s' '{"only":["a"],"set":[{"path":["settings","mode"],"value":"academic-writer"},{"path":["roles","x","model"],"value":"academic-writer"}],"mode":"academic-writer"}' > "$LC/ov.json"
check "legacy id: --mode, --mode=, --set settings.mode= and --set=settings.mode= are stored as academic-research; canon_overrides maps .mode and the settings.mode entry of .set only" "$(for a in "--mode academic-writer" "--mode=academic-writer" "--set settings.mode=academic-writer" "--set=settings.mode=academic-writer" "--mode Academic-Writer"; do overrides_from_args $a | jq -r .mode; done | tr '\n' ' ')$(canon_overrides "$LC/ov.json" | jq -c '[.mode, .set[0].value, .set[1].value, .only]')" "academic-research academic-research academic-research academic-research Academic-Writer [\"academic-research\",\"academic-research\",\"academic-writer\",[\"a\"]]"
# launch under the old id
LG="$TMP/aw-leg"; mkdir -p "$LG"; git -C "$LG" init -q -b main; LGG="$LG/.git"
aln() { (cd "$LG" && env -u ORCA_ROLES_CONFIG -u ORCA_ROLES_STATE HOME="$PH" PATH="$TMP/awbin:$PATH" ORCA_ROLES_KICKOFF="$TMP/awbin/kickoff" ORCA_ROLES_AGENT_CHECKS=1 "$PKL/bin/launch.sh" "$@" 2>&1); }
lgh() { cut -d= -f1 "$LGG/orca-roles.env" 2>/dev/null | tr '\n' ' '; }
lgmsg() { (cd "$LG" && KIT="$PK" planner_msg "$LGG/orca-roles.config.json" "planner exp" "$LGG/orca-roles.env" "" "" 0); }
rm -f "$TMP/aw-alive"; printf '{ "settings": { "mode": "academic-writer" } }' > "$LG/.orca-roles.json"
try aln --mode academic-writer
check "legacy id: the old id in .orca-roles.json and --mode launches the academic-research team, prints one note naming both sources, keeps a copy for the Planner, saves only the new id, and the Planner is told to relay it" "$RC:$(lgh):$(printf '%s\n' "$OUT" | grep -c "^Note: mode 'academic-writer' is now called 'academic-research'; the old name works until the next version. Found in: .orca-roles.json (.*/.orca-roles.json); the options of this run (--mode or the setup script in orca.yaml). Update it to academic-research.$"):$(printf '%s\n' "$OUT" | grep -c 'academic-writer'):$(printf '%s\n' "$OUT" | grep -c '^Mode: academic-research$'):$([ "$(cat "$LGG/orca-roles.legacy-note")" = "$(printf '%s\n' "$OUT" | grep '^Note: ')" ] && echo same):$(jq -r .mode "$LGG/orca-roles.overrides.json"):$(jq -r .settings.mode "$LGG/orca-roles.config.json"):$(lgmsg | grep -c 'Tell the user at startup, in one line: Note: mode .academic-writer. is now called')" "0:PLANNER EXP BOTH NOP :1:1:1:same:academic-research:academic-research:1"
rm -f "$LG/.orca-roles.json" "$LGG/orca-roles.env"
try aln --reset --mode academic-research
check "legacy id: with the new name nothing about the alias shows (no note, no copy for the Planner, nothing in its message)" "$RC:$(lgh):$(printf '%s\n' "$OUT" | grep -c 'academic-writer\|^Note:'):$([ -e "$LGG/orca-roles.legacy-note" ] && echo present):$(lgmsg | grep -c 'Tell the user')" "0:PLANNER EXP BOTH NOP :0::0"
rm -f "$LGG/orca-roles.env"; printf '{"only":["exp"],"enable":[],"disable":[],"set":[],"mode":"academic-writer"}\n' > "$LGG/orca-roles.overrides.json"
try aln
check "legacy id: saved options with the old mode id still select the same team, are rewritten to the new id with the role selection kept, and are named in the note; no normalized copy is left" "$RC:$(lgh):$(jq -c '[.mode, .only]' "$LGG/orca-roles.overrides.json"):$(printf '%s\n' "$OUT" | grep -c "^Note: .*Found in: this worktree's saved options (.*orca-roles.overrides.json)\. Update it to academic-research\.$"):$(find "$LGG" -name '*canon*' | wc -l | tr -d ' '):$(jq -r .settings.mode "$LGG/orca-roles.config.json")" "0:PLANNER EXP :[\"academic-research\",[\"exp\"]]:1:0:academic-research"
# a team open under the old id is the same mode
jq -c '.settings.mode="academic-writer"' "$LGG/orca-roles.config.json" > "$LC/c.json" && cp "$LC/c.json" "$LGG/orca-roles.config.json"
printf '{"only":["exp"],"enable":[],"disable":[],"set":[],"mode":"academic-writer"}\n' > "$LGG/orca-roles.overrides.json"; touch "$TMP/aw-alive"
try aln --mode academic-research
check "legacy id: a team open under the old id is the same mode: no 'Close the team first', no dropped role selection" "$RC:$(printf '%s\n' "$OUT" | grep -c 'Close the team first\|Mode changed'):$(jq -c '[.mode, .only]' "$LGG/orca-roles.overrides.json"):$(jq -r .settings.mode "$LGG/orca-roles.config.json")" "0:0:[\"academic-research\",[\"exp\"]]:academic-research"
# a failed launch changes nothing; --status reads the old id
printf '{"only":["exp"],"enable":[],"disable":[],"set":[],"mode":"academic-writer"}\n' > "$LGG/orca-roles.overrides.json"; jq -c '.settings.mode="academic-writer"' "$LGG/orca-roles.config.json" > "$LC/c.json" && cp "$LC/c.json" "$LGG/orca-roles.config.json"
LB="$(cat "$LGG/orca-roles.overrides.json" "$LGG/orca-roles.config.json" "$LGG/orca-roles.env" "$LGG/orca-roles.legacy-note" | cksum)"
try aln --only nonexist
check "legacy id: a launch that fails leaves the saved options, config, handles and note as they were, and no normalized copy" "$RC:$(cat "$LGG/orca-roles.overrides.json" "$LGG/orca-roles.config.json" "$LGG/orca-roles.env" "$LGG/orca-roles.legacy-note" | cksum):$(find "$LGG" -name '*canon*' | wc -l | tr -d ' ')" "1:$LB:0"
check "legacy id: --status reads a worktree configuration saved under the old id as academic-research, with its phase" "$(aln --status | grep '^Mode:\|^Phase:' | tr '\n' ' ')" "Mode: academic-research Phase: experiment "
SG="$TMP/aw-sc4"; mkdir -p "$SG"; printf '# orca-roles academic-writer\nmy\n' > "$SG/.gitignore"; try "$SC" "$SG"
check "legacy id: the scaffold treats a .gitignore with the old header as having the block: no second header, old header untouched" "$RC:$(grep -c '^# orca-roles' "$SG/.gitignore"):$(head -2 "$SG/.gitignore" | tr '\n' ' ')" "0:1:# orca-roles academic-writer my "
rm -f "$TMP/aw-alive"
rm -rf "$PK/prompts/academic-research"   # the other sections reuse this kit and expect the mode unavailable
}

sch_setup() {
SCH="$TMP/sch"; FX="$SCH/fx"; mkdir -p "$FX" "$SCH/tmp" "$SCH/state" "$SCH/run"
unset OPENALEX_API_KEY S2_API_KEY SCHOLAR_EMAIL
cat > "$FX/oa_search.json" <<'J'
{"results":[
{"id":"https://openalex.org/W1","doi":"https://doi.org/10.1000/ABC.1","title":"Deep\tLearning\nfor  Tabs","publication_year":2023,"authorships":[{"author":{"display_name":"Alma  Larkin"}}],"primary_location":{"source":{"display_name":"Nature"}},"cited_by_count":42,"open_access":{"is_oa":true}},
{"id":"https://openalex.org/W2","doi":"https://doi.org/10.48550/arXiv.2401.00001","title":"Arx paper","publication_year":2024,"authorships":[],"primary_location":null,"cited_by_count":0,"open_access":{"is_oa":false}},
{"id":"https://openalex.org/W3","doi":null,"title":"No doi","publication_year":null,"authorships":[{"author":{"display_name":null}}],"primary_location":{"source":null},"cited_by_count":null,"open_access":{"is_oa":null}},
{"id":"https://openalex.org/W4","doi":"https://doi.org/10.1000/four","title":"Beyond the limit","publication_year":2020,"authorships":[],"primary_location":null,"cited_by_count":1,"open_access":{"is_oa":false}}]}
J
cat > "$FX/pub.json" <<'J'
{"results":[{"id":"https://openalex.org/P1","display_name":"Small Pub","lineage":["https://openalex.org/P1"],"works_count":5},
{"id":"https://openalex.org/P2","display_name":"Big Child","lineage":["https://openalex.org/P9","https://openalex.org/P2"],"works_count":100},
{"id":"https://openalex.org/P3","display_name":"Mid","lineage":["https://openalex.org/P3"],"works_count":50}]}
J
cat > "$FX/src.json" <<'J'
{"results":[{"id":"https://openalex.org/S1","display_name":"Other Conf","works_count":900},
{"id":"https://openalex.org/S2","display_name":"neural information processing systems","works_count":10},
{"id":"https://openalex.org/S3","display_name":"NIPS Workshop","works_count":5}]}
J
echo '{"results":[]}' > "$FX/empty.json"
cat > "$FX/s2.json" <<'J'
{"data":[
{"paperId":"p1","externalIds":{"DOI":"10.1000/ABC.1"},"title":"Dup of OpenAlex","year":2023,"authors":[{"name":"X"}],"venue":"V","citationCount":1,"isOpenAccess":true},
{"paperId":"p2","externalIds":{"ArXiv":"2405.00005v2"},"title":"S2 arx","year":2024,"authors":[{"name":"Dan"}],"venue":"","citationCount":7,"isOpenAccess":true},
{"paperId":"p3","externalIds":{},"title":"Only\ts2","year":2020,"authors":[],"venue":"ICML","citationCount":0,"isOpenAccess":false},
{"paperId":"p4","externalIds":{"DOI":"10.48550/arXiv.2406.00006"},"title":"Cut by limit","year":2024,"authors":[],"venue":null,"citationCount":0,"isOpenAccess":true}]}
J
cat > "$FX/show1.json" <<'J'
{"id":"https://openalex.org/W77","doi":"https://doi.org/10.1000/SHOW.1","title":"A  Shown\nPaper","publication_year":2022,"publication_date":"2022-05-06","type":"article",
"authorships":[{"author":{"display_name":"Ann One"}},{"author":{"display_name":"Bo Two"}}],"primary_location":{"source":{"display_name":"Journal X","host_organization_name":"Pub Y"}},
"cited_by_count":5,"open_access":{"is_oa":true,"oa_url":"https://x.org/y.pdf"},"is_retracted":false,
"abstract_inverted_index":{"Abstract":[0],"We":[1],"study":[2,4],"cats":[3],"and":[5],"dogs.":[6]}}
J
cat > "$FX/show3.json" <<'J'
{"id":"https://openalex.org/W79","doi":"https://doi.org/10.48550/arXiv.2401.00001","title":"Arx via OpenAlex","publication_year":2024,"publication_date":"2024-01-02","type":"preprint","authorships":[],"primary_location":null,"cited_by_count":2,"open_access":{"is_oa":true,"oa_url":null},"is_retracted":false,"abstract_inverted_index":null}
J
cat > "$FX/show2.json" <<'J'
{"id":"https://openalex.org/W78","doi":null,"title":null,"publication_year":null,"publication_date":null,"type":null,"authorships":[],"primary_location":null,"cited_by_count":null,"open_access":{"is_oa":false,"oa_url":null},"is_retracted":true,"abstract_inverted_index":null}
J
sch_entry() { # id version title cat doi authors...
  local id="$1" v="$2" t="$3" cat="$4" doi="$5"; shift 5
  printf '<entry>\n <id>http://arxiv.org/abs/%sv%s</id>\n <updated>2024-02-04T10:00:00Z</updated>\n <published>2024-02-03T10:00:00Z</published>\n <title>%s</title>\n <summary>  Sum &amp; text\n line two. </summary>\n' "$id" "$v" "$t"
  for a in "$@"; do printf ' <author>\n  <name>%s</name>\n </author>\n' "$a"; done
  [ -n "$doi" ] && printf ' <arxiv:doi xmlns:arxiv="http://arxiv.org/schemas/atom">%s</arxiv:doi>\n' "$doi"
  printf ' <arxiv:primary_category xmlns:arxiv="http://arxiv.org/schemas/atom" term="%s" scheme="http://arxiv.org/schemas/atom"/>\n</entry>\n' "$cat"
}
sch_feed() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">\n <id>x</id>\n'; cat; printf '</feed>\n'; }
{ sch_entry 2401.00001 2 "Arx paper" cs.LG "" "Zed"; sch_entry 2402.00002 1 "Title &amp;
   more" cs.CL "" "Bob Smith" "Carol"; sch_entry hep-th/9901001 1 "Old style" hep-th "" "Old Author"; sch_entry 2403.00003 1 "Cut by limit" cs.AI "" "Q"; } | sch_feed > "$FX/ax_search.xml"
sch_entry 2401.00001 2 "Shown arXiv" cs.LG "10.1000/Mixed.Case" "First Au" "Second Au" | sch_feed > "$FX/ax_show.xml"
sch_feed < /dev/null > "$FX/ax_empty.xml"
printf '<entry>\n <id>http://arxiv.org/api/errors#incorrect_id_format</id>\n <summary>bad id</summary>\n</entry>\n' | sch_feed > "$FX/ax_err.xml"
cat > "$SCH/stublib.sh" <<'S'
# stub_args "$@": sets out, df and url; logs the contents and mode of every -H @file (User-Agent files to $SCH_LOG.ua, the others to $SCH_LOG.hdr),
# and what the pacing stamp and its lock look like at the time of the call (to $SCH_LOG.stamp)
stub_args() {
  out=""; df=""; local i=1 a j f lf
  while [ $i -le $# ]; do
    a="${!i}"
    case "$a" in
      -o) j=$((i+1)); out="${!j}";;
      -D) j=$((i+1)); df="${!j}";;
      -H) j=$((i+1)); case "${!j}" in @*) f="${!j#@}"; if head -1 "$f" | grep -q '^User-Agent:'; then lf="$SCH_LOG.ua"; else lf="$SCH_LOG.hdr"; fi
          { echo "${@: -1}"; cat "$f"; echo "MODE $(ls -l "$f" | cut -c1-10)"; } >> "$lf";; esac;;
    esac
    i=$((i+1))
  done
  url="${@: -1}"
  if [ -n "${SCHOLAR_STATE_DIR:-}" ]; then
    echo "stamp=$(cat "$SCHOLAR_STATE_DIR/orca-roles-scholar-arxiv.last" 2>/dev/null) lock=$([ -d "$SCHOLAR_STATE_DIR/orca-roles-scholar-arxiv.last.lock" ] && echo held || echo free)" >> "$SCH_LOG.stamp"
  fi
}
# stub_dump <status>: writes the -D file, one block per hop from $SCH_FX/ctype (one header line per hop, '-' for none; the last hop is the answer)
stub_dump() {
  [ -n "$df" ] || return 0
  : > "$df"
  local vals n k=0 v
  if [ -f "$SCH_FX/ctype" ]; then vals="$(cat "$SCH_FX/ctype")"; else vals="Content-Type: application/x-bibtex"; fi
  n="$(printf '%s\n' "$vals" | wc -l)"
  while IFS= read -r v; do
    k=$((k + 1))
    if [ "$k" -lt "$n" ]; then printf 'HTTP/1.1 302 Found\r\n' >> "$df"; else printf 'HTTP/2 %s\r\n' "$1" >> "$df"; fi
    [ "$v" = - ] || printf '%s\r\n' "$v" >> "$df"
    printf '\r\n' >> "$df"
  done <<EOT
$vals
EOT
}
S
cat > "$SCH/curl" <<'S'
#!/bin/bash
. "$SCH_FX/../stublib.sh"; stub_args "$@"
echo "$*" >> "$SCH_LOG"
case "$url" in
  *api.openalex.org/works/*) kind=oa; case "$url" in *doi:10.404*|*/W999*) body=404;; *doi:10.1000/retracted*|*/W78\?*) body=show2.json;; */W79\?*) body=show3.json;; *) body=show1.json;; esac;;
  *api.openalex.org/works?*) kind=oa; body=oa_search.json;;
  *api.openalex.org/publishers?*) kind=oa; case "$url" in *search=nomatch*) body=empty.json;; *) body=pub.json;; esac;;
  *api.openalex.org/sources?*) kind=oa; case "$url" in *search=zzz*) body=empty.json;; *) body=src.json;; esac;;
  *export.arxiv.org*) kind=ax; case "$url" in *id_list=9999*) body=ax_empty.xml;; *id_list=err*) body=ax_err.xml;; *id_list=*) body=ax_show.xml;; *) body=ax_search.xml;; esac;;
  *api.semanticscholar.org*) kind=s2; body=s2.json;;
  *) kind=x; body=empty.json;;
esac
cf="$SCH_FX/code.$kind"; code=200
if [ -f "$cf" ]; then code="$(head -1 "$cf")"; [ "$(wc -l < "$cf")" -gt 1 ] && tail -n +2 "$cf" > "$cf.n" && mv "$cf.n" "$cf"; fi
[ "$code" = FAIL ] && exit 7
if [ "$code" != 200 ]; then echo "oops $code" > "$out"
elif [ "$body" = 404 ]; then echo "<html>404</html>" > "$out"; code=404
else cp "$SCH_FX/$body" "$out"; fi
printf '%s' "$code"
S
chmod +x "$SCH/curl"
sc() { # runs scholar.sh with the stub; stdout $SCH/out, stderr $SCH/err, rc $SCH/rc, calls $SCH/log
  : > "$SCH/log"; rm -f "$SCH/log.hdr" "$SCH/log.ua" "$SCH/log.stamp"
  (cd "$SCH/run" && TMPDIR="$SCH/tmp" SCHOLAR_CURL="$SCH/curl" SCH_LOG="$SCH/log" SCH_FX="$FX" SCHOLAR_ARXIV_DELAY="${SCHOLAR_ARXIV_DELAY:-0}" SCHOLAR_RETRY_DELAY=0 SCHOLAR_STATE_DIR="$SCH/state" "$KIT/bin/scholar.sh" "$@" > "$SCH/out" 2> "$SCH/err"; echo $? > "$SCH/rc") || true
}
scn() { grep -c . "$SCH/log" || true; }
scg() { grep -c -- "$1" "$2" || true; }   # lines of a file with the fragment (0 is not a failure)
scu() { grep -cF -- "$1" "$SCH/log" || true; }   # calls whose line has the fragment
sch_codes() { rm -f "$FX"/code.* "$FX/ctype"; }
}

sec_scholar() {
sch_setup
# search, all sources without a key: rows, cleaning, ids, limit, cross-source dedupe, one call per source
sch_codes; sc search "graph neural" --limit 3
EXP="$(printf 'source\tid\tyear\tfirst_author\tvenue\tcitations\toa\ttitle\nopenalex\tdoi:10.1000/abc.1\t2023\tAlma Larkin\tNature\t42\tyes\tDeep Learning for Tabs\nopenalex\tarxiv:2401.00001\t2024\t-\t-\t0\tno\tArx paper\nopenalex\topenalex:W3\t-\t-\t-\t-\tno\tNo doi\narxiv\tarxiv:2402.00002\t2024\tBob Smith\tarXiv cs.CL\t-\tyes\tTitle & more\narxiv\tarxiv:hep-th/9901001\t2024\tOld Author\tarXiv hep-th\t-\tyes\tOld style')"
check "scholar search all: rows (cleaned, 8 columns, ids, limit, dedupe, order), empty stderr, exit 0, one call per source" "$(cat "$SCH/rc"):$(cat "$SCH/out"):$(cat "$SCH/err"):$(scn):$(scu 'https://api.openalex.org/works?search=graph%20neural&sort=relevance_score:desc&per_page=3&select=id,doi,title,publication_year,type,authorships,primary_location,cited_by_count,open_access'):$(scu 'https://export.arxiv.org/api/query?search_query=all:graph+AND+all:neural&start=0&max_results=3&sortBy=relevance&sortOrder=descending'):$(awk -F'\t' '{print NF}' "$SCH/out" | sort -u | tr '\n' ,)" "0:$EXP::2:1:1:8,"
# filters per source
sch_codes
sc search "rag models" --from 2023-01-01 --to 2024-12-31 --type proceedings --oa --sort citations --limit 05 --source openalex
R1="$(cat "$SCH/rc"):$(scu 'filter=from_publication_date:2023-01-01,to_publication_date:2024-12-31,type:conference-paper,is_oa:true&sort=cited_by_count:desc&per_page=5&select='):$(scn)"
sc search "x y" --type article --source openalex; R2="$(scu 'filter=type:article&sort='):$(scu 'filter=type:preprint')"
sc search "x" --type preprint --source openalex; R2="$R2:$(scu 'filter=type:preprint&sort=')"
sc search "graph neural" --from 2023-01-01 --source arxiv --sort date --limit 4; R3="$(scu 'search_query=all:graph+AND+all:neural+AND+submittedDate:%5B202301010000+TO+209912312359%5D&start=0&max_results=4&sortBy=submittedDate&sortOrder=descending')"
sc search "graph" --to 2024-12-31 --source arxiv --sort citations; R3="$R3:$(scu 'submittedDate:%5B199101010000+TO+202412312359%5D&start=0&max_results=10&sortBy=relevance&'):$(cat "$SCH/err")"
sc search "big" --publisher big --venue NeurIPS --source openalex
R4="$(cat "$SCH/rc"):$(scu 'publishers?search=big&per_page=25&select=id,display_name,lineage,works_count'):$(scu 'sources?search=Neural%20Information%20Processing%20Systems&per_page=10&select=id,display_name,works_count'):$(scu 'filter=primary_location.source.publisher_lineage:P2,primary_location.source.id:S2&sort='):$(cat "$SCH/err" | tr '\n' '|')"
sc search "q" --publisher nomatch --source openalex; R5="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(scu 'api.openalex.org/works?')"
sc search "q" --venue "zzz" --source openalex; R5="$R5:$(cat "$SCH/rc"):$(cat "$SCH/err")"
check "scholar search filters: OpenAlex filters/sort/per_page, arXiv dates and sort, notes" "$R1:$R2:$R3:$R4:$R5" "0:1:1:1:0:1:1:1:note: arxiv has no citation counts; sorted by relevance:0:1:1:1:note: publisher 'big' -> Big Child (P2)|note: other candidates: Mid (P3), Small Pub (P1)|note: venue 'NeurIPS' -> neural information processing systems (S2)|note: other candidates: Other Conf (S1), NIPS Workshop (S3)|:1:scholar.sh: no OpenAlex publisher matches 'nomatch':0:1:scholar.sh: no OpenAlex venue matches 'zzz'"

sch_codes
sc search "q" --sort date --source openalex; D1="$(cat "$SCH/rc"):$(scu 'sort=publication_date:desc&per_page=10&'):$(scu 'sort=relevance_score'):$(cat "$SCH/err")"
check "scholar search --sort date on OpenAlex sorts by publication_date:desc (not relevance_score)" "$D1" "0:1:0:"
echo 500 > "$FX/code.oa"; sc search "q" --publisher big --source openalex; P1="$(cat "$SCH/rc"):$(wc -c < "$SCH/out" | tr -d ' '):$(cat "$SCH/err"):$(scu 'publishers?search=big'):$(scu 'api.openalex.org/works?')"; sch_codes
check "scholar search: OpenAlex HTTP 500 while resolving --publisher -> exit 3, named in the error, empty stdout, no works call" "$P1" "3:0:scholar.sh: OpenAlex failed (HTTP 500) while resolving the publisher 'big':1:0"
echo 500 > "$FX/code.oa"; sc search "q" --venue NeurIPS --source openalex; P2="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(scu 'api.openalex.org/works?')"; sch_codes
check "scholar search: OpenAlex HTTP 500 while resolving --venue -> exit 3, says venue, no works call" "$P2" "3:scholar.sh: OpenAlex failed (HTTP 500) while resolving the venue 'NeurIPS':0"
# option validation: every bad call is a usage error (exit 1) and never reaches the network
sch_codes; BAD=""
for a in "search" "search   " "search q --from 2024-1-1" "search q --to 24-01-01" "search q --type book" "search q --sort best" "search q --source crossref" "search q --limit 0" "search q --limit 101" "search q --limit abc" "search q --limit -1" "search q --limit 1.5" "search q --limit" "search q --limit ''" "search q --oa --oa" "search q --limit 2 --limit 3" "search q --bogus" "search q q2" "search q --" "search q --venue" "show" "show a b" "show foo" "show arxiv:" "show doi:10.1" "show 10.1000/" "show openalex:Wabc" "show https://example.org/10.1000/x" "frobnicate"; do
  eval "sc $a"; [ "$(cat "$SCH/rc")" = 1 ] && [ "$(scn)" = 0 ] && [ ! -s "$SCH/out" ] || BAD="$BAD [$a rc=$(cat "$SCH/rc") calls=$(scn)]"
done
sc search q --limit 007; L1="$(cat "$SCH/rc"):$(scu 'per_page=7&')"
sc -h; H1="$(cat "$SCH/rc"):$(grep -c 'scholar.sh search' "$SCH/out")"; sc; H2="$(cat "$SCH/rc"):$(wc -c < "$SCH/out" | tr -d ' ')"
check "scholar usage errors: exit 1, no call, empty stdout; --limit 007 ok; -h exit 0; no arguments exit 1" "$BAD:$L1:$H1:$H2" ":0:1:0:1:1:0"
# skipped and refused sources
sch_codes
sc search q --type article; N1="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(scu export.arxiv.org)"
sc search q --publisher big; N2="$(cat "$SCH/rc"):$(cat "$SCH/err" | tr '\n' '|'):$(scu export.arxiv.org)"
sc search q --source arxiv --venue V; N3="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(scn)"
sc search q --source arxiv --type proceedings; N3="$N3:$(cat "$SCH/rc"):$(cat "$SCH/err")"
S2_API_KEY=k sc search q --type preprint; N4="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(scu semanticscholar)"
S2_API_KEY=k sc search q --publisher big; N5="$(cat "$SCH/rc"):$(scu semanticscholar):$(scu export.arxiv.org)"
sc search q --source s2 --type preprint; N6="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(scn)"
S2_API_KEY=k sc search q; N7="$(scu semanticscholar):$(scu export.arxiv.org):$(scu 'api.openalex.org/works?')"
check "scholar search: unsupported options skip a source under all, refuse it when explicit; s2 only with a key" "$N1|$N2|$N3|$N4|$N5|$N6|$N7" "0:note: arxiv skipped: arXiv only has preprints:0|0:note: arxiv skipped: arXiv has no publisher/venue filter|note: publisher 'big' -> Big Child (P2)|note: other candidates: Mid (P3), Small Pub (P1)|:0|1:scholar.sh: --source arxiv: arXiv has no publisher/venue filter:0:1:scholar.sh: --source arxiv: arXiv only has preprints|0:note: s2 skipped: Semantic Scholar has no preprint type:0|0:0:0|1:scholar.sh: --source s2: Semantic Scholar has no preprint type:0|1:1:1"
# Semantic Scholar: rows (id routing, limit, dedupe against OpenAlex), keyed relevance vs keyless bulk URLs
sch_codes
sc search "a-b c" --source s2 --limit 3
K1="$(cat "$SCH/rc"):$(cat "$SCH/out" | tr '\t' '~' | tr '\n' '|'):$(cat "$SCH/err"):$(scu 'search/bulk?query=a-b%20c&fields=title,year,externalIds,authors,venue,citationCount,isOpenAccess&sort=citationCount:desc')"
S2_API_KEY=k sc search "a-b c" --source s2 --from 2020-01-01 --type article --oa --venue "Nat Lang"
K2="$(scu 'paper/search?query=a%20b%20c&limit=10&fields=title,year,externalIds,authors,venue,citationCount,isOpenAccess'):$(scu 'publicationDateOrYear=2020-01-01:'):$(scu 'publicationTypes=JournalArticle'):$(scu '&openAccessPdf'):$(scu '&venue=Nat%20Lang'):$(scu search/bulk)"
sc search "q" --source s2 --sort date --to 2021-05-05 --type proceedings; K3="$(scu 'search/bulk?query=q&'):$(scu 'sort=publicationDate:desc'):$(scu 'publicationDateOrYear=:2021-05-05'):$(scu 'publicationTypes=Conference'):$(cat "$SCH/err")"
S2_API_KEY=k sc search "q" --source s2 --sort citations; K4="$(scu 'search/bulk'):$(scu 'sort=citationCount:desc'):$(scu 'paper/search?')"
S2_API_KEY=k sc search "graph neural" --limit 3; K5="$(cut -f1,2 "$SCH/out" | tr '\t' '~' | tr '\n' '|')"
check "scholar s2: id routing, limit, dedupe, keyless bulk note, filters, keyed relevance endpoint, order openalex/arxiv/s2" "$K1|$K2|$K3|$K4|$K5" "0:source~id~year~first_author~venue~citations~oa~title|s2~doi:10.1000/abc.1~2023~X~V~1~yes~Dup of OpenAlex|s2~arxiv:2405.00005~2024~Dan~-~7~yes~S2 arx|s2~s2:p3~2020~-~ICML~0~no~Only s2|:note: Semantic Scholar without S2_API_KEY has no relevance ranking; sorted by citations:1|1:1:1:1:1:0|1:1:1:1:|1:1:0|source~id|openalex~doi:10.1000/abc.1|openalex~arxiv:2401.00001|openalex~openalex:W3|arxiv~arxiv:2402.00002|arxiv~arxiv:hep-th/9901001|s2~arxiv:2405.00005|s2~s2:p3|"
# failing sources: partial success keeps the rest, total failure exits 3 and prints nothing, 429 retried for OpenAlex/S2 only
sch_codes
echo 500 > "$FX/code.oa"; sc search q --limit 2; F1="$(cat "$SCH/rc"):$(cut -f1 "$SCH/out" | sort -u | tr '\n' ,):$(cat "$SCH/err")"
echo 500 > "$FX/code.oa"; echo 503 > "$FX/code.ax"; sc search q; F2="$(cat "$SCH/rc"):$(wc -c < "$SCH/out" | tr -d ' '):$(cat "$SCH/err" | tr '\n' '|')"
sch_codes; echo FAIL > "$FX/code.oa"; sc search q --source openalex; F3="$(cat "$SCH/rc"):$(wc -c < "$SCH/out" | tr -d ' '):$(cat "$SCH/err" | tr '\n' '|')"
sch_codes; echo 200 > "$FX/code.oa"; echo 200 > "$FX/code.ax"; printf 'x\n' > /dev/null
cp "$FX/ax_err.xml" "$FX/ax_search.keep"; cp "$FX/ax_search.xml" "$FX/ax_search.good"; cp "$FX/ax_err.xml" "$FX/ax_search.xml"; sc search q --source arxiv; F4="$(cat "$SCH/rc"):$(wc -c < "$SCH/out" | tr -d ' '):$(cat "$SCH/err" | tr '\n' '|')"; cp "$FX/ax_search.good" "$FX/ax_search.xml"
sch_codes; printf '429\n429\n200\n' > "$FX/code.oa"; sc search q --source openalex --limit 1; F5="$(cat "$SCH/rc"):$(scn):$(grep -c '^openalex' "$SCH/out")"
sch_codes; printf '429\n429\n429\n200\n' > "$FX/code.oa"; sc search q --source openalex; F6="$(cat "$SCH/rc"):$(scn):$(cat "$SCH/err" | tr '\n' '|')"
sch_codes; echo 429 > "$FX/code.ax"; sc search q --source arxiv; F7="$(cat "$SCH/rc"):$(scn):$(cat "$SCH/err" | tr '\n' '|')"
sch_codes; echo 429 > "$FX/code.s2"; sc search q --source s2; F8="$(cat "$SCH/rc"):$(scn):$(cat "$SCH/err" | tr '\n' '|')"
sch_codes; printf '403\n200\n' > "$FX/code.s2"; S2_API_KEY=k sc search q --source s2 --limit 2; F9="$(cat "$SCH/rc"):$(scn):$(grep -c '^s2' "$SCH/out"):$(grep -c 'x-api-key' "$SCH/log.hdr"):$(cat "$SCH/err" | tr '\n' '|')"
check "scholar failures: partial success keeps the rest, total failure exits 3 with empty stdout, retries only for OpenAlex/S2" "$F1|$F2|$F3|$F4|$F5|$F6|$F7|$F8|$F9" "0:arxiv,source,:warning: openalex failed (HTTP 500)|3:0:warning: openalex failed (HTTP 500)|warning: arxiv failed (HTTP 503)|scholar.sh: every source failed||3:0:warning: openalex failed (HTTP 000)|scholar.sh: every source failed||3:0:warning: arxiv returned an error: bad id|scholar.sh: every source failed||0:3:1|3:3:warning: openalex failed (HTTP 429)|scholar.sh: every source failed||3:1:warning: arxiv failed (HTTP 429)|scholar.sh: every source failed||3:3:note: Semantic Scholar without S2_API_KEY has no relevance ranking; sorted by citations|warning: s2 failed (HTTP 429)|scholar.sh: every source failed||0:2:2:1:warning: S2_API_KEY was rejected; retried without it|"
# keys: only in a header file read by curl (-H @file), never in an argument, a URL, stdout, stderr or a file left behind; the temp dir is removed
sch_codes; LEAK=0; SEEN=""
for a in "search q --publisher big --venue zz" "show 10.1000/x.1" "show arxiv:2401.00001" "search q --sort date"; do
  for fail in 0 1; do
    sch_codes; [ "$fail" = 1 ] && { echo 500 > "$FX/code.oa"; echo 429 > "$FX/code.s2"; }
    OPENALEX_API_KEY=KEYOA_SECRET S2_API_KEY=KEYS2_SECRET SCHOLAR_EMAIL=me@x.org sc $a
    cat "$SCH/out" "$SCH/err" "$SCH/log" > "$SCH/all"
    grep -q 'KEYOA_SECRET\|KEYS2_SECRET' "$SCH/all" && LEAK=$((LEAK + 1))
    grep -q 'me@x.org' "$SCH/log" && LEAK=$((LEAK + 1000))
    grep -rq 'KEYOA_SECRET\|KEYS2_SECRET' "$SCH/tmp" "$SCH/state" "$SCH/run" 2>/dev/null && LEAK=$((LEAK + 10))
    [ -z "$(ls -A "$SCH/tmp")" ] || LEAK=$((LEAK + 100))
    [ -f "$SCH/log.hdr" ] && SEEN="$SEEN$(scg 'Authorization: Bearer KEYOA_SECRET' "$SCH/log.hdr")$(scg 'x-api-key: KEYS2_SECRET' "$SCH/log.hdr")."
  done
done
sch_codes; sc search q --source openalex; U1="$(scg ' -A ' "$SCH/log")$(scg 'User-Agent: orca-roles-scholar$' "$SCH/log.ua"):$([ -f "$SCH/log.hdr" ] && echo hdr || echo nohdr)"
SCHOLAR_EMAIL=me@x.org sc search q --source openalex; U2="$(scg ' -A ' "$SCH/log")$(scg 'User-Agent: orca-roles-scholar (mailto:me@x.org)$' "$SCH/log.ua")$(scg 'MODE -rw-------$' "$SCH/log.ua")$(scg 'me@x.org' "$SCH/log")"
OPENALEX_API_KEY=KEYOA_SECRET sc search q --source openalex; U3="$(scg '-H @' "$SCH/log"):$(scg 'KEYOA' "$SCH/log")"
check "scholar keys: header file only (-H @file), no key in arguments, output or leftovers; the User-Agent goes in a 0600 header file, never in -A, and the email never reaches a command line of the API calls" "$LEAK:$SEEN:$U1:$U2:$U3" "0:30.10.10.10.11.13.:01:nohdr:0110:1:0"
# show on OpenAlex: fields in order, cleaning, abstract, not found, API error, and every identifier form reaches the same work
sch_codes; sc show 10.1000/SHOW.1
EXPS="$(printf 'id: doi:10.1000/show.1\ntitle: A Shown Paper\nyear: 2022\ndate: 2022-05-06\ntype: article\nauthors: Ann One; Bo Two\nvenue: Journal X\npublisher: Pub Y\ndoi: 10.1000/show.1\narxiv: -\ncitations: 5\noa: yes\noa_url: https://x.org/y.pdf\nretracted: no\nabstract: We study cats study and dogs.')"
bvu() { grep -o 'https://[^ ]*' "$SCH/log" | sed -e 's#https://api.crossref.org/works/#CR #' -e 's#https://export.arxiv.org/api/query?id_list=#AX #' | tr '\n' ' '; }
V1="$(cat "$SCH/rc"):$([ "$(cat "$SCH/out")" = "$EXPS" ] && echo same || cat "$SCH/out"):$(cat "$SCH/err"):$(scu 'https://api.openalex.org/works/doi:10.1000/show.1?select=id,doi,title,publication_year,publication_date,type,authorships,primary_location,cited_by_count,open_access,is_retracted,abstract_inverted_index')"
sc show 10.1000/retracted; V2="$(cat "$SCH/rc"):$(sed -n '1p;2p;3p;6p;8p;9p;10p;11p;13p;14p;15p' "$SCH/out" | tr '\n' '|')"
for id in "doi:10.1000/SHOW.1" "DOI:10.1000/SHOW.1" "https://doi.org/10.1000/SHOW.1" "http://doi.org/10.1000/SHOW.1" "10.1000/SHOW.1" "doi: 10.1000/SHOW.1" "HTTPS://DOI.ORG/10.1000/SHOW.1" "HTTP://DOI.ORG/10.1000/SHOW.1" "Https://Doi.Org/10.1000/SHOW.1"; do sc show "$id"; V3="${V3:-}$(cat "$SCH/rc")$(scu 'works/doi:10.1000/show.1?')"; done
sc show "10.1000/a?b#c%d e"; V4="$(scu 'works/doi:10.1000/a%3Fb%23c%25de?select=')"
sc show doi:10.404/none; V5="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(wc -c < "$SCH/out" | tr -d ' ')"
echo 500 > "$FX/code.oa"; sc show 10.1000/x; V6="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(scn)"; sch_codes
sc show 10.48550/arXiv.2401.00001; V7="$(cat "$SCH/rc"):$(scu api.openalex.org):$(scu 'export.arxiv.org/api/query?id_list=2401.00001')"
check "scholar show (OpenAlex): fields and cleaning, abstract, retracted, identifier forms, DOI encoding, 404 -> 2, error -> 3, arXiv DOI never asked to OpenAlex" "$V1|$V2|$V3|$V4|$V5|$V6|$V7" "0:same::1|0:id: openalex:W78|title: -|year: -|authors: -|publisher: -|doi: -|arxiv: -|citations: -|oa_url: -|retracted: yes|abstract: -||010101010101010101|1|2:scholar.sh: doi:10.404/none not found in OpenAlex:0|3:scholar.sh: OpenAlex failed (HTTP 500):1|0:0:1"
sch_codes; sc show openalex:W78; W1="$(cat "$SCH/rc"):$(scu 'https://api.openalex.org/works/W78?select='):$(head -1 "$SCH/out"):$(scg '^arxiv: -$' "$SCH/out")"
sc show OPENALEX:w78; W1="$W1:$(cat "$SCH/rc"):$(scu 'https://api.openalex.org/works/W78?select='):$(head -1 "$SCH/out")"
sc show openalex:W77; W2="$(cat "$SCH/rc"):$(scu 'https://api.openalex.org/works/W77?select='):$(head -1 "$SCH/out")"
sc show openalex:W79; W3="$(cat "$SCH/rc"):$(scg '^id: arxiv:2401.00001$' "$SCH/out"):$(scg '^arxiv: 2401.00001$' "$SCH/out"):$(scg '^doi: 10.48550/arxiv.2401.00001$' "$SCH/out"):$(scu export.arxiv.org)"
sc show OpenAlex:w999; W4="$(cat "$SCH/rc"):$(scu 'works/W999?select='):$(cat "$SCH/err"):$(wc -c < "$SCH/out" | tr -d ' ')"
W5=""; for b in "openalex:" "openalex:W" "openalex:Wx1" "openalex:W1x" "openalex:W1 2x"; do sc show "$b"; W5="$W5$(cat "$SCH/rc")$(scn)"; done
check "scholar show openalex:W<id>: any case of prefix and W, uppercase W in URL, DOI-less work prints openalex:W, a work with a DOI prints its DOI id, arXiv-DOI work fills 'arxiv:', missing -> 2, malformed -> 1" "$W1|$W2|$W3|$W4|$W5" "0:1:id: openalex:W78:1:0:1:id: openalex:W78|0:1:id: doi:10.1000/show.1|0:1:1:1:0|2:1:scholar.sh: OpenAlex:w999 not found in OpenAlex:0|1010101010"
# redirects and header file mode: no API call follows redirects (-L), with or without a key; the key and User-Agent header files are 0600
sch_codes; OPENALEX_API_KEY=KEYOA_SECRET S2_API_KEY=KEYS2_SECRET sc search q
R1="$(scn):$(scg ' -L ' "$SCH/log"):$(scu 'export.arxiv.org'):$(scg 'MODE -rw-------$' "$SCH/log.hdr"):$(scg MODE "$SCH/log.hdr"):$(scg 'MODE -rw-------$' "$SCH/log.ua"):$(scg MODE "$SCH/log.ua"):$(scg '-H @.* -H @' "$SCH/log")"
OPENALEX_API_KEY=KEYOA_SECRET sc search q --publisher big --venue zz --source openalex; R2="$(scn):$(scg ' -L ' "$SCH/log")"
sc search q --publisher big --venue zz --source openalex; R3="$(scn):$(scg ' -L ' "$SCH/log")"
sch_codes; printf '403\n200\n' > "$FX/code.s2"; S2_API_KEY=KEYS2_SECRET sc search q --source s2; R4="$(scn):$(scg ' -L ' "$SCH/log")"
sch_codes; echo 302 > "$FX/code.oa"; OPENALEX_API_KEY=KEYOA_SECRET sc search q --source openalex; R5="$(cat "$SCH/rc"):$(tr '\n' '|' < "$SCH/err"):$(scn)"
check "scholar redirects: no API call is made with -L (key or not), the key and User-Agent header files are 0600 and both are passed on a keyed call, a 3xx is a failure" "$R1|$R2|$R3|$R4|$R5" "3:0:1:2:2:3:3:2|3:0|3:0|2:0|3:warning: openalex failed (HTTP 302)|scholar.sh: every source failed|:1"
# show on arXiv (paced, never OpenAlex), and the pacing across runs
sch_codes; sc show arxiv:2401.00001v3
EXPA="$(printf 'id: arxiv:2401.00001\ntitle: Shown arXiv\nyear: 2024\ndate: 2024-02-03\ntype: preprint\nauthors: First Au; Second Au\nvenue: arXiv cs.LG\npublisher: -\ndoi: 10.1000/mixed.case\narxiv: 2401.00001\ncitations: -\noa: yes\noa_url: https://arxiv.org/pdf/2401.00001v2\nretracted: -\nabstract: Sum & text line two.')"
A1="$(cat "$SCH/rc"):$([ "$(cat "$SCH/out")" = "$EXPA" ] && echo same || cat "$SCH/out"):$(scu 'https://export.arxiv.org/api/query?id_list=2401.00001'):$(scu api.openalex.org)"
A2=""; for id in "ARXIV:2401.00001" "https://arxiv.org/abs/2401.00001v2" "arxiv:hep-th/9901001v2" "10.48550/ARXIV.2401.00001" "HTTPS://ARXIV.ORG/ABS/2401.00001v2" "http://arxiv.org/abs/2401.00001" "HTTP://ARXIV.ORG/ABS/hep-th/9901001"; do sc show "$id"; A2="${A2:-}$(cat "$SCH/rc")$(scu api.openalex.org)$(scu 'id_list=')"; done
sc show arxiv:9999.99999; A3="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(wc -c < "$SCH/out" | tr -d ' ')"
sc show arxiv:err; A4="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(wc -c < "$SCH/out" | tr -d ' ')"
echo 500 > "$FX/code.ax"; sc show arxiv:2401.00001; A5="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(scn)"; sch_codes
# pacing: the stamp is written after an arXiv call; a run within the delay waits for the rest of it; an old, empty or garbled stamp does not
rm -f "$SCH/state/orca-roles-scholar-arxiv.last"
SCHOLAR_ARXIV_DELAY=2 sc show arxiv:2401.00001; P1="$([ -f "$SCH/state/orca-roles-scholar-arxiv.last" ] && echo stamp || echo nostamp)"
T0="$(date +%s)"; SCHOLAR_ARXIV_DELAY=2 sc show arxiv:2401.00001; P2="$(( $(date +%s) - T0 >= 1 ? 1 : 0 ))"
P3=""; for st in 1000 "" garbage "$(( $(date +%s) + 3 ))"; do printf '%s\n' "$st" > "$SCH/state/orca-roles-scholar-arxiv.last"; T0="$(date +%s)"; SCHOLAR_ARXIV_DELAY=2 sc show arxiv:2401.00001; P3="${P3:-}$(( $(date +%s) - T0 <= 1 ? 0 : 1 ))$(cat "$SCH/rc")"; done
P5="$([ "$(cat "$SCH/state/orca-roles-scholar-arxiv.last")" -le "$(( $(date +%s) + 1 ))" ] && echo rewritten || echo kept)"
SCHOLAR_ARXIV_DELAY=2 sc search q --source arxiv; P4="$(scu export.arxiv.org)"
check "scholar show (arXiv): fields, id forms and old-style ids, never OpenAlex, not found 2, error 3; pacing stamp and wait" "$A1|$A2|$A3|$A4|$A5|$P1:$P2:$P3:$P4:$P5" "0:same:1:0|001001001001001001001|2:scholar.sh: arxiv:9999.99999 not found in arXiv:0|3:scholar.sh: arXiv returned an error: bad id:0|3:scholar.sh: arXiv failed (HTTP 500):1|stamp:1:00000000:1:rewritten"
# pacing across runs and processes: the stamp is taken before the call and the wait is d+1 whole seconds after it; a lock dir serializes the runs
LK="$SCH/state/orca-roles-scholar-arxiv.last.lock"; ST="$SCH/state/orca-roles-scholar-arxiv.last"
rm -rf "$LK"; S0="$(date +%s)"; echo "$S0" > "$ST"
SCHOLAR_ARXIV_DELAY=2 sc show arxiv:2401.00001; G1="$(cat "$SCH/rc"):$(( $(date +%s) - S0 >= 3 ? 1 : 0 ))"; G2="$(sed -n 's/^stamp=\([0-9]*\) lock=.*/\1/p' "$SCH/log.stamp")"
check "scholar arXiv pacing: a stamp in the current second waits d+1 whole seconds, the stamp is already written when the call is made, the lock is free during the call and gone after" "$G1:$(( ${G2:-0} >= S0 + 3 ? 1 : 0 )):$(sed -n 's/.*lock=//p' "$SCH/log.stamp"):$([ -e "$LK" ] && echo left || echo gone):$([ "$(cat "$ST")" = "$G2" ] && echo same || echo moved)" "0:1:1:free:gone:same"
echo 1000 > "$ST"; mkdir "$LK"; ( sleep 2; rmdir "$LK" ) & T0="$(date +%s)"
SCHOLAR_ARXIV_DELAY=2 sc show arxiv:2401.00001; wait; H1="$(cat "$SCH/rc"):$(( $(date +%s) - T0 >= 1 ? 1 : 0 )):$([ -e "$LK" ] && echo left || echo gone):$(scu export.arxiv.org)"
mkdir "$LK"; T0="$(date +%s)"; sc show arxiv:2401.00001; H2="$(cat "$SCH/rc"):$(( $(date +%s) - T0 <= 1 ? 1 : 0 )):$([ -d "$LK" ] && echo untouched || echo removed):$(scu export.arxiv.org)"; rmdir "$LK"
check "scholar arXiv pacing: a run waits while another holds the lock and leaves nothing behind; with the delay 0 there is no lock at all" "$H1:$H2" "0:1:gone:1:0:1:untouched:1"
mkdir "$LK"; echo 1000 > "$ST"; T0="$(date +%s)"; SCHOLAR_ARXIV_DELAY=1 sc show arxiv:2401.00001; Z="$(( $(date +%s) - T0 ))"
check "scholar arXiv pacing: a lock nobody releases is taken over after 30 s (not before, not never) and removed" "$(cat "$SCH/rc"):$(( Z >= 30 && Z <= 120 ? 1 : 0 )):$([ -e "$LK" ] && echo left || echo gone):$(scu export.arxiv.org)" "0:1:gone:1"
# no usable state dir or no lock: the call is made unpaced (no lock, no sleep, no stamp), one note on stderr per run, same exit code; never a hang
SD="$SCH/state"; rm -rf "$SD" "$SCH/nostate"; T0="$(date +%s)"
SCHOLAR_ARXIV_DELAY=3 sc show arxiv:2401.00001; U1="$(cat "$SCH/rc"):$(( $(date +%s) - T0 <= 2 ? 1 : 0 )):$(cat "$SCH/err"):$(scu export.arxiv.org):$([ -e "$SD" ] && echo created || echo none)"
printf 'x' > "$SCH/nostate"; T0="$(date +%s)"; SCHOLAR_ARXIV_DELAY=3 sc search q --source arxiv; U2="$(cat "$SCH/rc"):$(( $(date +%s) - T0 <= 2 ? 1 : 0 )):$(grep -c 'not paced' "$SCH/err" || true)"
SCHOLAR_ARXIV_DELAY=0 sc show arxiv:2401.00001; U3="$(cat "$SCH/rc"):$(wc -c < "$SCH/err" | tr -d ' ')"; mkdir -p "$SD"
U4=skipped; if [ "$(id -u)" != 0 ]; then chmod 555 "$SD"; SCHOLAR_ARXIV_DELAY=3 sc show arxiv:2401.00001; U4="$(cat "$SCH/rc"):$(cat "$SCH/err"):$(scu export.arxiv.org):$(ls -A "$SD" | wc -l | tr -d ' ')"; chmod 755 "$SD"; fi
check "scholar arXiv pacing: a missing or read-only state dir (or delay 0) never hangs: the call is made at once without lock, sleep or stamp, with the note 'arXiv calls are not paced: <dir> is not a writable directory'" "$U1|$U2|$U3|$U4" "0:1:scholar.sh: arXiv calls are not paced: $SD is not a writable directory:1:none|0:1:1|0:0|$([ "$(id -u)" != 0 ] && echo "0:scholar.sh: arXiv calls are not paced: $SD is not a writable directory:1:0" || echo skipped)"
mkdir -p "$LK"; : > "$LK/pin"; echo 1000 > "$ST"; T0="$(date +%s)"; SCHOLAR_ARXIV_DELAY=1 sc show arxiv:2401.00001; Z="$(( $(date +%s) - T0 ))"
check "scholar arXiv pacing: a lock that cannot be removed ends the wait once after 30 s (no restart), the call is made unpaced with the note 'cannot take the lock', the stamp is not touched" "$(cat "$SCH/rc"):$(( Z >= 30 && Z <= 120 ? 1 : 0 )):$(cat "$SCH/err"):$(scu export.arxiv.org):$(cat "$ST"):$([ -e "$LK/pin" ] && echo kept || echo gone)" "0:1:scholar.sh: arXiv calls are not paced: cannot take the lock $ST.lock:1:1000:kept"
rm -rf "$LK"
rm -f "$ST"; mkdir "$ST"; SCHOLAR_ARXIV_DELAY=1 sc show arxiv:2401.00001; Y="$(cat "$SCH/rc"):$(grep -c 'not paced' "$SCH/err" || true):$(scu export.arxiv.org):$([ -e "$LK" ] && echo left || echo gone)"; rmdir "$ST"
check "scholar arXiv pacing: a lock taken but a stamp that cannot be written is silent (no 'cannot take the lock' note), the call is made and the lock is released" "$Y" "0:0:1:gone"
# bibtex and verify: doi.org / Crossref / arXiv stub serving files named after the request; anything else is flagged
BV="$FX/bv"; rm -rf "$BV"; mkdir -p "$BV" "$SCH/bvg"; git -C "$SCH/bvg" init -q
cat > "$SCH/curl2" <<'S'
#!/bin/bash
. "$SCH_FX/../stublib.sh"; stub_args "$@"
echo "$*" >> "$SCH_LOG"
case "$url" in
  https://doi.org/*) n="doi_$(printf '%s' "${url#https://doi.org/}" | sed 's/[^A-Za-z0-9]/_/g')";;
  https://api.crossref.org/works/*) u="${url#https://api.crossref.org/works/}"; n="cr_$(printf '%s' "${u%%\?*}" | sed 's/[^A-Za-z0-9]/_/g')";;
  https://export.arxiv.org/api/query?id_list=*) n="ax_$(printf '%s' "${url##*id_list=}" | sed 's/[^A-Za-z0-9]/_/g')";;
  *) echo "$url" >> "$SCH_LOG.bad"; exit 7;;
esac
code=200; [ -f "$SCH_FX/bv/$n.code" ] && code="$(cat "$SCH_FX/bv/$n.code")"
[ "$code" = FAIL ] && exit 7
if [ "$code" = 200 ] && [ -f "$SCH_FX/bv/$n" ]; then cp "$SCH_FX/bv/$n" "$out"
elif [ "$code" = 200 ]; then echo "<html>404</html>" > "$out"; code=404
else echo "oops $code" > "$out"; fi
stub_dump "$code"
printf '%s' "$code"
S
chmod +x "$SCH/curl2"
bv() { # like sc, for bibtex/verify: cwd $BVDIR (default $SCH/run), stub curl2, no Crossref delay unless set
  : > "$SCH/log"; rm -f "$SCH/log.bad" "$SCH/log.hdr" "$SCH/log.ua" "$SCH/log.stamp"
  (cd "${BVDIR:-$SCH/run}" && TMPDIR="$SCH/tmp" SCHOLAR_CURL="$SCH/curl2" SCH_LOG="$SCH/log" SCH_FX="$FX" SCHOLAR_ARXIV_DELAY=0 SCHOLAR_CROSSREF_DELAY="${SCHOLAR_CROSSREF_DELAY:-0}" SCHOLAR_RETRY_DELAY=0 SCHOLAR_STATE_DIR="$SCH/state" "$KIT/bin/scholar.sh" "$@" > "$SCH/out" 2> "$SCH/err"; echo $? > "$SCH/rc") || true
}
bvr() { echo "$(cat "$SCH/rc"):$(wc -c < "$SCH/out" | tr -d ' '):$(cat "$SCH/err" | tr '\n' '|'):$(scn)"; }   # rc:stdout bytes:stderr:calls
echo ' @article{Varga_2023, title={Large language models encode clinical knowledge}, DOI={10.1038/s41586-023-06291-2}, journal={Nature}, author={Varga, Karl and Lindqvist, Sigrid}, year={2023}, month=July, pages={172–180} }' > "$BV/doi_10_1038_s41586_023_06291_2"
printf '@misc{https://doi.org/10.48550/arxiv.2005.11401,\n  doi = {10.48550/ARXIV.2005.11401},\n  author = {Okafor, Paulo and Ibarra, Elena},\n  title = {Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks},\n  publisher = {arXiv},\n  year = {2020}\n}\n' > "$BV/doi_10_48550_arXiv_2005_11401"
echo '<html>Error</html>' > "$BV/doi_10_1000_html"; echo 500 > "$BV/doi_10_1000_err.code"; echo FAIL > "$BV/doi_10_1000_net.code"
cr() { local e="${4:-}"; [ -n "$e" ] || e="{}"; jq -nc --arg t "$1" --arg a "$2" --argjson y "$3" --argjson extra "$e" '{status:"ok",message:({title:[$t],author:[{family:$a}],issued:{"date-parts":[[$y]]}} + $extra)}'; }
BERT="BERT: Pre-training of Deep Bidirectional Transformers for Language Understanding"
cr "$BERT" Hartwell 2019 > "$BV/cr_10_18653_v1_n19_1423"
cr "RETRACTED: Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children" Castellan 1998 '{"updated-by":[{"DOI":"10.1016/s0140-6736(04)15715-2","type":"correction"},{"DOI":"10.1016/s0140-6736(10)60175-4","type":"retraction"}]}' > "$BV/cr_10_1016_s0140_6736_97_11096_0"
cr "Retraction—Ileal" "The Editors" 2010 '{"update-to":[{"DOI":"10.1016/s0140-6736(97)11096-0","type":"retraction"}]}' > "$BV/cr_10_1016_s0140_6736_10_60175_4"
cr "Paper with concern" Ng 2021 '{"updated-by":[{"DOI":"10.1/eoc","type":"expression_of_concern"}]}' > "$BV/cr_10_1_concern"
cr "Paper withdrawn" Ng 2021 '{"updated-by":[{"DOI":"10.1/wd","type":"withdrawal"}]}' > "$BV/cr_10_1_withdrawn"
cr "Paper erratum" Ng 2021 '{"updated-by":[{"DOI":"10.1/er","type":"erratum"}]}' > "$BV/cr_10_1_erratum"
jq -nc '{status:"ok",message:{title:["No author paper"],issued:{"date-parts":[[null]]}}}' > "$BV/cr_10_1_noauthor"
echo '<html>oops</html>' > "$BV/cr_10_1_html"; echo 500 > "$BV/cr_10_1_err.code"; echo FAIL > "$BV/cr_10_1_net.code"; echo 429 > "$BV/cr_10_1_rate.code"
sch_entry 2005.11401 1 "Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks" cs.CL "" "Paulo Okafor" "Elena Ibarra" | sch_feed > "$BV/ax_2005_11401"
sch_feed < /dev/null > "$BV/ax_9999_99999"
W="$SCH/bvw"; rm -rf "$W"; mkdir -p "$W"
bvent() { printf '@article{%s, title={%s}, author={%s}, year={%s}, doi={%s}}\n' "$@"; }
E1='@article{varga2023large, title={{Large language models encode clinical knowledge}}, DOI={10.1038/s41586-023-06291-2}, journal={Nature}, author={Varga, Karl and Lindqvist, Sigrid}, year={2023}, month = jul, pages={172--180} }'
E2="$(printf '@misc{okafor2020retrieval,\n  doi = {10.48550/ARXIV.2005.11401},\n  author = {Okafor, Paulo and Ibarra, Elena},\n  title = {{Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks}},\n  publisher = {arXiv},\n  year = {2020}\n}')"
# bibtex without --add: fixed entry on stdout (key, braced title, month macro, pages --), Accept header, DOI lowercased, arXiv id -> arXiv DOI, nothing written
bv bibtex doi:10.1038/S41586-023-06291-2; X1="$(bvr):$([ "$(cat "$SCH/out")" = "$E1" ] && echo same || echo differs):$(scu 'https://doi.org/10.1038/s41586-023-06291-2'):$(scu '-H Accept: application/x-bibtex'):$(scu ' -L ')"
bv bibtex arxiv:2005.11401v2; X2="$(bvr):$([ "$(cat "$SCH/out")" = "$E2" ] && echo same || echo differs):$(scu 'https://doi.org/10.48550/arXiv.2005.11401')"
check "scholar bibtex: fixed doi.org entry on stdout (doi and arxiv id), Accept header, follows redirects, empty stderr, nothing written" "$X1|$X2|$(ls "$SCH/run" | wc -l | tr -d ' ')" "0:$(( $(printf '%s' "$E1" | wc -c) + 1 ))::1:same:1:1:1|0:$(printf '%s\n' "$E2" | wc -c | tr -d ' ')::1:same:1|0"
# bibtex: the LAST Content-Type of the doi.org answer (the -D file holds every hop) must contain application/x-bibtex, in any case; same failure as a body that does not start with '@'
CT=""
for c in 'Content-Type: application/x-bibtex' 'content-type: Application/X-BibTeX; charset=utf-8' 'CONTENT-TYPE:application/x-bibtex' 'Content-Type: text/html\nContent-Type: application/x-bibtex' 'Content-Type: application/x-bibtex\nContent-Type: text/html' 'Content-Type: text/html' 'Content-Type: application/json' '-' 'X-Content-Type: application/x-bibtex'; do
  printf '%b\n' "$c" > "$FX/ctype"; bv bibtex doi:10.1038/S41586-023-06291-2
  CT="$CT$(cat "$SCH/rc"):$([ "$(cat "$SCH/out")" = "$E1" ] && echo same || wc -c < "$SCH/out" | tr -d ' '):$(tr '\n' '|' < "$SCH/err")|"
done; rm -f "$FX/ctype"; bv bibtex doi:10.1038/S41586-023-06291-2; CT="$CT$(scu ' -D ')"
check "scholar bibtex content type: accepted when the last hop says application/x-bibtex (case and parameters free); html, json, none, an X- header or an earlier hop only -> exit 3 'doi.org failed (HTTP 200)', empty stdout" "$CT" "0:same:|0:same:|0:same:|0:same:|3:0:scholar.sh: doi.org failed (HTTP 200)||3:0:scholar.sh: doi.org failed (HTTP 200)||3:0:scholar.sh: doi.org failed (HTTP 200)||3:0:scholar.sh: doi.org failed (HTTP 200)||3:0:scholar.sh: doi.org failed (HTTP 200)||1"
# the email never goes to doi.org (which redirects to publishers): plain User-Agent, with -L, no -A, no email anywhere in the call
SCHOLAR_EMAIL=me@x.org bv bibtex doi:10.1038/S41586-023-06291-2; EM1="$(cat "$SCH/rc"):$(scg ' -L ' "$SCH/log"):$(scg ' -A ' "$SCH/log"):$(scg 'me@x.org' "$SCH/log"):$(scg 'User-Agent: orca-roles-scholar$' "$SCH/log.ua"):$(scg 'me@x.org' "$SCH/log.ua")"
SCHOLAR_EMAIL=me@x.org bv bibtex arxiv:2005.11401; EM2="$(cat "$SCH/rc"):$(scg ' -L ' "$SCH/log"):$(scg 'me@x.org' "$SCH/log" "$SCH/log.ua")"
check "scholar bibtex with SCHOLAR_EMAIL: the doi.org request follows redirects with the plain User-Agent (header file) and the email is nowhere in the call" "$EM1|$EM2" "0:1:0:0:1:0|0:1:0"
# bibtex failures: usage before any call, 404 -> 2, other status / curl failure / HTML page with 200 -> 3; no file, no stdout
Y=""; for a in "openalex:W12" "10.9999/none" "10.1000/err" "10.1000/net" "10.1000/html" "nonsense"; do bv bibtex "$a" --add --bib "$W/f.bib"; Y="$Y$(bvr)|"; done
bv bibtex 10.1/x --bib "$W/f.bib"; Y="$Y$(bvr)|"; bv bibtex 10.1038/s41586-023-06291-2 --add; Y="$Y$(bvr)|"; bv bibtex; Y="$Y$(bvr)|"; bv bibtex 10.1/x --add --add --bib "$W/f.bib"; Y="$Y$(bvr)"
check "scholar bibtex failures: usage errors make no call, 404 -> 2, 5xx/curl/HTML-200 -> 3, empty stdout, nothing written" "$Y:$([ -e "$W/f.bib" ] && echo written || echo none)" "1:0:scholar.sh: bibtex needs a DOI or an arXiv id (run: scholar.sh show <id> to see its DOI)|:0|2:0:scholar.sh: 10.9999/none not found at doi.org|:1|3:0:scholar.sh: doi.org failed (HTTP 500)|:1|3:0:scholar.sh: doi.org failed (HTTP 000)|:1|3:0:scholar.sh: doi.org failed (HTTP 200)|:1|1:0:scholar.sh: unrecognized identifier 'nonsense' (use doi:<doi> or arxiv:<id>)|:0|1:0:scholar.sh: --bib needs --add|:0|1:0:scholar.sh: not in a git repository; pass --bib <path>|:0|1:0:scholar.sh: bibtex needs exactly one identifier|:0|1:0:scholar.sh: option --add given twice|:0:none"
# bibtex: a 200 body that is not one complete entry (truncated, unbalanced, text after the closing brace, '}' before the '@') is refused untouched
printf '@article{x, title={T}' > "$BV/doi_10_1000_trunc"; printf '@article{x, title={T}}}\n' > "$BV/doi_10_1000_extra"; printf '@article{x, title={{T}}\n' > "$BV/doi_10_1000_open"
printf '@article{x, title={T}}\ntrailing\n' > "$BV/doi_10_1000_tail"; printf '}\n@article{x, title={T}}\n' > "$BV/doi_10_1000_lead"; printf '@article{x,\r\n title={A {nested} {T}},\r\n year={2020}\r\n}\r\n\r\n' > "$BV/doi_10_1000_crlf"
Q=""; for a in trunc extra open tail lead; do bv bibtex "10.1000/$a" --add --bib "$W/q.bib"; Q="$Q$(bvr)|"; done; bv bibtex 10.1000/crlf --add --bib "$W/q.bib"; Q="$Q$(bvr):$(cat "$SCH/out"):$(grep -c . "$W/q.bib")"
check "scholar bibtex: incomplete or unbalanced doi.org body -> exit 3 'incomplete BibTeX entry', empty stdout, nothing written; leading-@ rule first; nested braces and CRLF accepted" "$Q" "3:0:scholar.sh: doi.org returned an incomplete BibTeX entry|:1|3:0:scholar.sh: doi.org returned an incomplete BibTeX entry|:1|3:0:scholar.sh: doi.org returned an incomplete BibTeX entry|:1|3:0:scholar.sh: doi.org returned an incomplete BibTeX entry|:1|3:0:scholar.sh: doi.org failed (HTTP 200)|:1|0:11:note: added 2020nested to $W/q.bib|:1:2020nested:4"
# --bib on something that exists and is not a regular file: exit 1 before any call, no raw shell error; symlink to a file works, dangling link as before
mkdir -p "$W/d.bib" "$W/dd"; ln -sfn "$W/dd" "$W/lnk-dir.bib"; ln -sfn "$W/nowhere.bib" "$W/dangling.bib"; printf '@article{k, doi={10.18653/v1/n19-1423}, title={%s}, author={Hartwell, J}, year={2019}}\n' "$BERT" > "$W/real.bib"; ln -sfn "$W/real.bib" "$W/lnk-file.bib"
NR=""; for f in d.bib lnk-dir.bib; do bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/$f"; NR="$NR$(bvr)|"; bv verify --bib "$W/$f"; NR="$NR$(bvr)|"; done
bv verify --bib "$W/lnk-file.bib"; NR="$NR$(cat "$SCH/rc"):$(tail -n 1 "$SCH/out")|"; bv verify --bib "$W/dangling.bib"; NR="$NR$(bvr)|"; bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/lnk-file.bib"; NR="$NR$(cat "$SCH/rc"):$(grep -c '^@' "$W/real.bib")"
check "scholar --bib on a directory (or link to one): bibtex --add and verify exit 1 'is not a regular file' with no call; link to a file works; dangling link keeps the old messages" "$NR" "1:0:scholar.sh: $W/d.bib is not a regular file|:0|1:0:scholar.sh: $W/d.bib is not a regular file|:0|1:0:scholar.sh: $W/lnk-dir.bib is not a regular file|:0|1:0:scholar.sh: $W/lnk-dir.bib is not a regular file|:0|0:k$(printf '\t')ok$(printf '\t')-|1:0:scholar.sh: $W/dangling.bib not found|:0|0:2"
# --add: new nested file, default <git top>/article/refs.bib, append-only with the right separators, empty file
bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/n/e/refs.bib"; Z1="$(bvr):$(cat "$W/n/e/refs.bib" | cmp -s - <(printf '%s\n' "$E1") && echo exact || echo differs):$(cat "$SCH/out")"
BVDIR="$SCH/bvg" bv bibtex 10.1038/s41586-023-06291-2 --add; Z2="$(cmp -s "$SCH/bvg/article/refs.bib" <(printf '%s\n' "$E1") && echo exact || echo differs):$(cat "$SCH/out")"
printf '%% my comment\n@string{nat = "Nature"}\r\n\n@article{old,\n  title = {Old}, author = "Zed, A", doi = "10.1/OLD",\n  year = 1999\n}' > "$W/nonl.bib"; cp "$W/nonl.bib" "$W/nonl0.bib"
bv bibtex arxiv:2005.11401 --add --bib "$W/nonl.bib"; Z3="$(bvr):$(head -c "$(wc -c < "$W/nonl0.bib")" "$W/nonl.bib" | cmp -s - "$W/nonl0.bib" && echo kept || echo CHANGED):$(cmp -s <(tail -c +"$(( $(wc -c < "$W/nonl0.bib") + 1 ))" "$W/nonl.bib") <(printf '\n\n%s\n' "$E2") && echo tail-ok || echo tail-bad)"
printf '@article{old,\n  doi = {10.1/old}\n}\n' > "$W/nl.bib"; cp "$W/nl.bib" "$W/nl0.bib"; bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/nl.bib"
Z4="$(cmp -s <(tail -c +"$(( $(wc -c < "$W/nl0.bib") + 1 ))" "$W/nl.bib") <(printf '\n%s\n' "$E1") && echo tail-ok || echo tail-bad)"
: > "$W/zero.bib"; bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/zero.bib"; Z5="$(cmp -s "$W/zero.bib" <(printf '%s\n' "$E1") && echo exact || echo differs)"
check "scholar bibtex --add: creates dirs/file, default path in a git repo, append-only with blank-line separator, no existing byte touched, stdout key, note on stderr" "$Z1|$Z2|$Z3|$Z4|$Z5" "0:15:note: added varga2023large to $W/n/e/refs.bib|:1:exact:varga2023large|exact:varga2023large|0:20:note: added okafor2020retrieval to $W/nonl.bib|:1:kept:tail-ok|tail-ok|exact"
# --add duplicates by DOI (case, https prefix, quoted, other key, arXiv DOI in any case) never write; key collisions
printf '@article{theirs, doi = "https://doi.org/10.1038/S41586-023-06291-2"}\n@misc{lw, doi={https://doi.org/10.48550/ARXIV.2005.11401}}\n' > "$W/dup.bib"; cp "$W/dup.bib" "$W/dup0.bib"
bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/dup.bib"; D1="$(bvr):$(cat "$SCH/out")"; bv bibtex arxiv:2005.11401 --add --bib "$W/dup.bib"; D2="$(bvr):$(cat "$SCH/out")"
check "scholar bibtex --add: a DOI already present (case, prefix, quotes, arXiv DOI) is not added: file untouched, key on stdout, note, exit 0" "$D1|$D2|$(cmp -s "$W/dup.bib" "$W/dup0.bib" && echo same || echo CHANGED)" "0:7:note: already in $W/dup.bib as theirs|:1:theirs|0:3:note: already in $W/dup.bib as lw|:1:lw|same"
printf '@article{Varga2023Large,\n doi={10.1/zzz}\n}\n' > "$W/col.bib"; bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/col.bib"; C1="$(cat "$SCH/out")"
sed -e 's/10.1038\/s41586-023-06291-2/10.1038\/other/' "$BV/doi_10_1038_s41586_023_06291_2" > "$BV/doi_10_1038_other"; bv bibtex 10.1038/other --add --bib "$W/col.bib"; C2="$(cat "$SCH/out")"
: > "$W/z.bib"; for l in "" b c d e f g h i j k l m n o p q r s t u v w x y z; do echo "@article{varga2023large$l, doi={10.1/q$l}}" >> "$W/z.bib"; done; cp "$W/z.bib" "$W/z0.bib"
bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/z.bib"; C3="$(bvr):$(cmp -s "$W/z.bib" "$W/z0.bib" && echo same || echo CHANGED)"
grep -v 'largez,' "$W/z0.bib" > "$W/z2.bib"; bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/z2.bib"; C4="$(cat "$SCH/out"):$(tail -n 1 "$W/z2.bib" | cut -c1-24)"
check "scholar bibtex --add: taken key (any case) gets b, c, ...; 26 taken -> exit 3 untouched; z still free" "$C1|$C2|$C3|$C4" "varga2023largeb|varga2023largec|3:0:scholar.sh: no free key for varga2023large in $W/z.bib|:1:same|varga2023largez:@article{varga2023largez"
# verify: table of statuses over every identity/retraction/mismatch path, exit codes, pacing, request URLs
BVF() { printf '%s\n' '@comment{ignored @article{fake, doi={10.1/x}} }' '@string{n = "N"}'; }
{ BVF
bvent ok1 "$BERT" "Hartwell, Jonas and Ito, Mei" 2019 10.18653/V1/N19-1423
bvent sub "BERT: Pre-training of Deep Bidirectional Transformers" "Jonas Hartwell and Ito, Mei" 2019 https://doi.org/10.18653/v1/n19-1423
bvent bad "Totally other" "Smith, J" 2020 10.18653/v1/n19-1423
bvent wake "Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children" "Castellan, AJ and Moreau, SH" 1998 10.1016/S0140-6736\(97\)11096-0
bvent notice Retraction Editors 2010 10.1016/s0140-6736\(10\)60175-4
bvent missing T "A, B" 2000 10.9999/none
printf '@article{nodoi, title={T}, author={A, B}, year={2000}}\n'
printf '@misc{rag, title = "Retrieval-Augmented Generation for Knowledge-Intensive {NLP} Tasks", author = "Okafor, Paulo and Ibarra, Elena", year = 2024, eprint = {arXiv:2005.11401v3}, archivePrefix = {arXiv}}\n'
bvent ragdoi "Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks" "Okafor, Paulo" 2024 10.48550/arXiv.2005.11401
printf '@misc{axmissing, title={T}, author={A}, year={2000}, eprint={9999.99999}, archiveprefix={arXiv}}\n@misc{eprintonly, title={T}, author={A}, year={2000}, eprint={2005.11401}}\n'
bvent concern "Paper with concern" "Ng, A" 2021 10.1/concern
bvent wd "Paper withdrawn" "Ng, A" 2021 10.1/withdrawn
bvent er "Paper erratum" "Ng, A" 2021 10.1/erratum
bvent noauth "No author paper" "Ng, A" 2021 10.1/noauthor
printf '@article{notitle, author={Hartwell, Jonas}, year={2019}, doi={10.18653/v1/n19-1423}}\n'
bvent html t a 1 10.1/html; bvent err t a 1 10.1/err; bvent net t a 1 10.1/net; bvent rate t a 1 10.1/rate; } > "$W/v.bib"
sed -i.bak 's/\\(/(/g; s/\\)/)/g' "$W/v.bib"; rm -f "$W/v.bib.bak"; cp "$W/v.bib" "$W/v0.bib"
bv verify --bib "$W/v.bib"
T="$(printf '\t')"
EXPV="key${T}status${T}detail
ok1${T}ok${T}-
sub${T}warn${T}title differs (subtitle?)
bad${T}fail${T}title mismatch: \"$BERT\"; first author mismatch: Hartwell; year mismatch: 2019
wake${T}retracted${T}title mismatch: \"RETRACTED: Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children\"; correction (10.1016/s0140-6736(04)15715-2); retracted (10.1016/s0140-6736(10)60175-4); title says RETRACTED
notice${T}fail${T}title differs (subtitle?); this DOI is a notice, not the paper
missing${T}notfound${T}not in Crossref
nodoi${T}nodoi${T}no doi or arXiv eprint
rag${T}ok${T}-
ragdoi${T}ok${T}-
axmissing${T}notfound${T}not in arXiv
eprintonly${T}nodoi${T}no doi or arXiv eprint
concern${T}warn${T}expression of concern (10.1/eoc)
wd${T}retracted${T}retracted (10.1/wd)
er${T}ok${T}correction (10.1/er)
noauth${T}warn${T}first author unknown; year unknown
notitle${T}fail${T}title mismatch: \"$BERT\"
html${T}error${T}unreadable Crossref response
err${T}error${T}Crossref HTTP 500
net${T}error${T}Crossref HTTP 000
rate${T}error${T}Crossref HTTP 429"
V1="$(cat "$SCH/rc"):$([ "$(cat "$SCH/out")" = "$EXPV" ] && echo table-ok || echo table-differs):$(cat "$SCH/err"):$(awk -F'\t' '{print NF}' "$SCH/out" | sort -u | tr '\n' ,):$(cmp -s "$W/v.bib" "$W/v0.bib" && echo same || echo CHANGED):$([ -f "$SCH/log.bad" ] && echo NETWORK || echo contained)"
check "scholar verify: one TAB line per entry in file order (ok/warn/fail/retracted/notfound/nodoi/error), every identity and retraction path, exit 4, bib untouched; Crossref DOI lowercased, arXiv id without prefix/version, one call per looked-up entry" "$V1:$(bvu)" "4:table-ok::3,:same:contained:CR 10.18653/v1/n19-1423 CR 10.18653/v1/n19-1423 CR 10.18653/v1/n19-1423 CR 10.1016/s0140-6736(97)11096-0 CR 10.1016/s0140-6736(10)60175-4 CR 10.9999/none AX 2005.11401 AX 2005.11401 AX 9999.99999 CR 10.1/concern CR 10.1/withdrawn CR 10.1/erratum CR 10.1/noauthor CR 10.18653/v1/n19-1423 CR 10.1/html CR 10.1/err CR 10.1/net CR 10.1/rate "
# exit codes
{ bvent a "$BERT" "Hartwell, J" 2019 10.18653/v1/n19-1423; bvent b t a 1 10.1/err; } > "$W/m1.bib"
{ bvent b t a 1 10.1/err; bvent c t a 1 10.1/rate; } > "$W/m2.bib"
{ bvent b t a 1 10.1/err; bvent a x "Ng, A" 2019 10.1/concern; } > "$W/m3.bib"
{ bvent b t a 1 10.1/err; printf '@misc{n, title={t}}\n'; } > "$W/m4.bib"
: > "$W/empty.bib"; printf '%% c\n@comment{x}\n@string{a="b"}\n' > "$W/cm.bib"
X=""; for f in m1 m2 m3 m4 empty cm; do bv verify --bib "$W/$f.bib"; X="$X$(cat "$SCH/rc"):$(wc -l < "$SCH/out" | tr -d ' ') "; done
check "scholar verify exit codes: ok+error 0, only errors 3, error+fail 4, error+nodoi 4, no entries 0 with header only" "$X" "0:3 3:3 4:3 4:3 0:1 0:1 "
# verify: arXiv error branches (HTTP error, an arXiv error feed, an id that cannot be a query), each reported per entry and never fatal
echo 500 > "$BV/ax_5000_00500.code"; cp "$FX/ax_err.xml" "$BV/ax_5000_00501"
{ printf '@misc{axhttp, title={T}, author={A}, year={2000}, eprint={5000.00500}, archiveprefix={arXiv}}\n'; printf '@misc{axfeed, title={T}, author={A}, year={2000}, eprint={5000.00501}, archiveprefix={arXiv}}\n'
  printf '@misc{axbad, title={T}, author={A}, year={2000}, eprint={bad id!}, archiveprefix={arXiv}}\n'; printf '@misc{axdoi, title={T}, author={A}, year={2000}, doi={10.48550/arXiv.5000.00500}}\n'; } > "$W/ax.bib"
bv verify --bib "$W/ax.bib"
check "scholar verify arXiv errors: HTTP status, error feed and unusable id are 'error' rows with their detail; all-error run exits 3; bib untouched; the bad id is never requested" "$(cat "$SCH/rc"):$(tr '\t' '~' < "$SCH/out" | tr '\n' '|'):$(bvu)" "3:key~status~detail|axhttp~error~arXiv HTTP 500|axfeed~error~arXiv returned an error: bad id|axbad~error~unusable arXiv id|axdoi~error~arXiv HTTP 500|:AX 5000.00500 AX 5000.00501 AX 5000.00500 "
rm -f "$BV/ax_5000_00500.code" "$BV/ax_5000_00501"
bv verify --bib "$W/nope.bib"; U1="$(bvr)"; bv verify x; U2="$(bvr)"; bv verify --x; U3="$(bvr)"; bv verify --bib; U4="$(bvr)"; bv verify; U5="$(bvr)"
mkdir -p "$SCH/bvg/article"; cp "$W/m1.bib" "$SCH/bvg/article/refs.bib"; BVDIR="$SCH/bvg" bv verify; U7="$(cat "$SCH/rc"):$(wc -l < "$SCH/out" | tr -d ' ')"
check "scholar verify usage: missing file / bad args / no git without --bib -> exit 1 with no call; default <git top>/article/refs.bib" "$U1|$U2|$U3|$U4|$U5|$U7" "1:0:scholar.sh: $W/nope.bib not found|:0|1:0:scholar.sh: verify takes no argument (got 'x')|:0|1:0:scholar.sh: unknown option '--x'|:0|1:0:scholar.sh: option --bib needs a value|:0|1:0:scholar.sh: not in a git repository; pass --bib <path>|:0|0:3"
# odd files: CRLF, mixed-case type/fields, tab and space in keys, bare/quoted values, unreadable file
printf '@Article{CRLF,\r\n  Title = {%s},\r\n  Author = {Hartwell, Jonas},\r\n  Year = {2019},\r\n  DOI = {10.18653/v1/n19-1423}\r\n}\r\n' "$BERT" > "$W/crlf.bib"
printf '@article{k\tx, title={%s}, author={Hartwell, J}, year={2019}, doi="10.18653/v1/n19-1423"}\n@article{sp ace,doi={10.1/err}}\n' "$BERT" > "$W/odd.bib"
bv verify --bib "$W/crlf.bib"; O1="$(cat "$SCH/out" | tail -n 1)"; bv verify --bib "$W/odd.bib"; O2="$(tail -n +2 "$SCH/out" | tr '\t\n' '~|')"
O3=skipped; if [ "$(id -u)" != 0 ]; then cp "$W/m1.bib" "$W/ro.bib"; chmod 000 "$W/ro.bib"; bv verify --bib "$W/ro.bib"; O3="$(cat "$SCH/rc"):$(wc -c < "$SCH/out" | tr -d ' '):$(tail -n 1 "$SCH/err")"; bv bibtex 10.1038/s41586-023-06291-2 --add --bib "$W/ro.bib"; O3="$O3:$(cat "$SCH/rc"):$(tail -n 1 "$SCH/err")"; chmod 644 "$W/ro.bib"; fi
check "scholar verify odd files: CRLF and mixed-case fields, tab in key collapsed, quoted doi; unreadable .bib -> exit 3 for verify and bibtex --add" "$O1|$O2|$O3" "CRLF${T}ok${T}-|k x~ok~-|sp ace~error~Crossref HTTP 500||3:0:scholar.sh: cannot read $W/ro.bib:3:scholar.sh: cannot read $W/ro.bib"
# Crossref pacing (SCHOLAR_CROSSREF_DELAY between calls, none before the first), SCHOLAR_EMAIL in the User-Agent
{ bvent a "$BERT" "Hartwell, J" 2019 10.18653/v1/n19-1423; bvent b "$BERT" "Hartwell, J" 2019 10.18653/v1/n19-1423; } > "$W/p.bib"
T0="$(date +%s)"; SCHOLAR_CROSSREF_DELAY=2 bv verify --bib "$W/p.bib"; PA="$(( $(date +%s) - T0 >= 2 ? 1 : 0 ))"
head -n 1 "$W/p.bib" > "$W/p1.bib"; T0="$(date +%s)"; SCHOLAR_CROSSREF_DELAY=5 bv verify --bib "$W/p1.bib"; PB="$(( $(date +%s) - T0 <= 3 ? 1 : 0 ))"
SCHOLAR_EMAIL='a+b@x.org' bv verify --bib "$W/p.bib"
check "scholar verify: Crossref delay between calls but not before the first; SCHOLAR_EMAIL goes in the User-Agent header file only, no mailto parameter in the URL, no -A, no redirects" "$PA$PB:$(scu 'mailto'):$(scg 'User-Agent: orca-roles-scholar (mailto:a+b@x.org)$' "$SCH/log.ua"):$(scg 'a+b@x.org' "$SCH/log"):$(scg ' -A \| -L ' "$SCH/log"):$(cat "$SCH/rc")" "11:0:2:0:0:0"
# pdf / pdfs: stub curl3 maps a URL (query stripped, non-alphanumerics -> _) to a fixture in fx/pd; no fixture -> 404, <name>.code overrides the status, FAIL -> curl exit 7
PD="$FX/pd"; mkdir -p "$PD"
cat > "$SCH/curl3" <<'S'
#!/bin/bash
. "$SCH_FX/../stublib.sh"; stub_args "$@"
echo "$*" >> "$SCH_LOG"
n="$(printf '%s' "${url%%\?*}" | sed -e 's#^https\{0,1\}://##' -e 's/[^A-Za-z0-9]/_/g')"
code=200; [ -f "$SCH_FX/pd/$n.code" ] && code="$(cat "$SCH_FX/pd/$n.code")"
[ "$code" = FAIL ] && exit 7
if [ "$code" = 200 ] && [ -f "$SCH_FX/pd/$n" ]; then cp "$SCH_FX/pd/$n" "$out"
elif [ "$code" = 200 ]; then echo "<html>404</html>" > "$out"; code=404
else echo "oops $code" > "$out"; fi
printf '%s' "$code"
S
chmod +x "$SCH/curl3"
pdfbody() { printf '%%PDF-1.4\n'; head -c "$1" /dev/zero | tr '\0' a; }
pdfbody 3000 > "$PD/arxiv_org_pdf_1706_03762"; pdfbody 3100 > "$PD/pub_example_org_p_pdf"; pdfbody 3200 > "$PD/repo_example_org_h_pdf"; pdfbody 3300 > "$PD/oa_example_org_o_pdf"
{ printf '<html>'; head -c 3000 /dev/zero | tr '\0' a; } > "$PD/pub_example_org_h_pdf"; cp "$PD/pub_example_org_h_pdf" "$PD/pub_example_org_n_html"
echo FAIL > "$PD/pub_example_org_f_pdf.code"; echo 500 > "$PD/repo_example_org_f_pdf.code"
echo '{"oa_locations":[{"host_type":"repository","url_for_pdf":"https://repo.example.org/p.pdf"},{"host_type":"publisher","url_for_pdf":"https://pub.example.org/p.pdf"},{"host_type":"publisher","url_for_pdf":null},{"host_type":"repository","url_for_pdf":"https://pub.example.org/p.pdf"}]}' > "$PD/api_unpaywall_org_v2_10_1_pub"
echo '{"oa_locations":[{"host_type":"repository","url_for_pdf":"https://repo.example.org/h.pdf"},{"host_type":"publisher","url_for_pdf":"https://pub.example.org/h.pdf"}]}' > "$PD/api_unpaywall_org_v2_10_1_html"
echo '{"oa_locations":[{"host_type":"publisher","url_for_pdf":"https://pub.example.org/f.pdf"},{"host_type":"repository","url_for_pdf":"https://repo.example.org/f.pdf"}]}' > "$PD/api_unpaywall_org_v2_10_1_fail"
echo '{"oa_locations":[{"host_type":"repository","url_for_pdf":"https://arxiv.org/pdf/1706.03762"}]}' > "$PD/api_unpaywall_org_v2_10_1_viaarxiv"
echo '{"open_access":{"oa_url":"https://oa.example.org/o.pdf"}}' > "$PD/api_openalex_org_works_doi_10_1_oaonly"
echo '{"open_access":{"oa_url":"https://pub.example.org/n.html"}}' > "$PD/api_openalex_org_works_doi_10_1_none"
echo '{"open_access":{"oa_url":"https://pub.example.org/f.pdf"}}' > "$PD/api_openalex_org_works_doi_10_1_fail"
W2="$SCH/pw"; rm -rf "$W2"; mkdir -p "$W2/article"; git -C "$W2" init -q; W2R="$(cd "$W2" && pwd -P)"
cat > "$W2/article/refs.bib" <<'B'
@article{brandt2017attention, title={{Attention} is all you need}, author={Brandt, A}, year={2017}, eprint={1706.03762v5}, archivePrefix={arXiv}}
@article{oa2020, doi={10.1/OAonly}, title={}, author={A, B}, year={2020}}
@article{pub2020, doi={10.1/pub}, title={Pub  paper}, author={A, B}, year={2020}}
@article{html2020, doi={10.1/html}, title={Html first}, author={A, B}, year={2020}}
@article{none2020, doi={10.1/none}, title={Nothing | here, {at} all}, author={A, B}, year={2020}}
@article{fail2020, doi={10.1/fail}, title={Fails}, author={A, B}, year={2020}}
@misc{okafor2020rag, doi={10.48550/ARXIV.2005.11401}, title={RAG}, author={Okafor, P}, year={2020}}
@article{via2020, doi={10.1/viaarxiv}, title={Via arxiv host}, author={A, B}, year={2020}}
@article{a/../b, doi={10.1/evil}, title={Evil}, author={A, B}, year={2020}}
@article{noid2020, title={No id}, author={A, B}, year={2020}}
B
pd() { : > "$SCH/log"; rm -f "$SCH/log.hdr" "$SCH/log.ua" "$SCH/log.stamp"; (cd "${PWD2:-$W2}" && TMPDIR="$SCH/tmp" SCHOLAR_CURL="$SCH/curl3" SCH_LOG="$SCH/log" SCH_FX="$FX" SCHOLAR_ARXIV_DELAY="${SCHOLAR_ARXIV_DELAY:-0}" SCHOLAR_RETRY_DELAY=0 SCHOLAR_STATE_DIR="$SCH/state" "$KIT/bin/scholar.sh" "$@" > "$SCH/out" 2> "$SCH/err"; echo $? > "$SCH/rc") || true; }
pdr() { echo "$(cat "$SCH/rc"):$(tr '\n' '|' < "$SCH/out"):$(tr '\n' '|' < "$SCH/err"):$(scn)"; }
LIT2="$W2/article/literature"; TB="$(printf '\t')"
pd pdf arxiv:1706.03762v5
check "scholar pdf arXiv id: matched through eprint, one paced arXiv call with size/redirect/time caps, file identical, manifest row, 'None' list" "$(pdr):$(cmp -s "$LIT2/pdfs/brandt2017attention.pdf" "$PD/arxiv_org_pdf_1706_03762" && echo same || echo differs):$(scu 'https://arxiv.org/pdf/1706.03762'):$(scu '--max-time 60 --max-redirs 10 --max-filesize 50000000'):$(cat "$LIT2/manifest.tsv" | tr '\t\n' '~|'):$(tr '\n' '|' < "$LIT2/missing.md")" "0:downloaded brandt2017attention article/literature/pdfs/brandt2017attention.pdf|::1:same:1:1:key~id~title~pdf~source|brandt2017attention~arxiv:1706.03762~Attention is all you need~oa~https://arxiv.org/pdf/1706.03762|:# PDFs to download by hand||None: every paper in the manifest has its PDF.|"
OPENALEX_API_KEY=sekrit-key pd pdf 10.1/oaonly
check "scholar pdf DOI without SCHOLAR_EMAIL: Unpaywall skipped with a note and never called, OpenAlex oa_url used, empty title -> '-', key only in the header file" "$(pdr):$(scu unpaywall):$(scu sekrit-key):$(scu 'api.openalex.org/works/doi:10.1/oaonly?select=open_access'):$(grep -c '^oa2020' "$LIT2/manifest.tsv")" "0:downloaded oa2020 article/literature/pdfs/oa2020.pdf|:note: Unpaywall skipped: set SCHOLAR_EMAIL to use it|:2:0:0:1:1"
SCHOLAR_EMAIL='a+b@x.org' pd pdf doi:10.1/Pub
P1="$(pdr):$(scu 'https://api.unpaywall.org/v2/10.1/pub?email=a%2Bb%40x.org'):$(scg 'User-Agent: orca-roles-scholar (mailto:a+b@x.org)$' "$SCH/log.ua"):$(scg 'User-Agent: orca-roles-scholar$' "$SCH/log.ua"):$(scu 'repo.example.org'):$(scu openalex):$(cat "$SCH/out" "$SCH/err" "$LIT2/manifest.tsv" "$LIT2/missing.md" | grep -c 'a+b@x.org' || true):$(scg ' -L ' "$SCH/log")$(scg ' -A ' "$SCH/log")"
SCHOLAR_EMAIL='a+b@x.org' pd pdf 10.1/html
check "scholar pdf Unpaywall (email in its User-Agent, downloads plain): publisher URLs first, null and duplicate URLs dropped, stop at the first PDF, email URL-encoded and never in outputs; HTML first then PDF -> 'tried ... not a PDF', source is the PDF URL" "$P1|$(pdr):$(grep "^html2020" "$LIT2/manifest.tsv" | cut -f4,5)" "0:downloaded pub2020 article/literature/pdfs/pub2020.pdf|::2:1:1:1:0:0:0:10|0:downloaded html2020 article/literature/pdfs/html2020.pdf|:tried https://pub.example.org/h.pdf: not a PDF|:3:oa${TB}https://repo.example.org/h.pdf"
SCHOLAR_EMAIL=me@x.org pd pdf 10.1/none; N1="$(pdr):$(scg 'User-Agent: orca-roles-scholar (mailto:me@x.org)$' "$SCH/log.ua"):$(scg 'User-Agent: orca-roles-scholar$' "$SCH/log.ua")"
SCHOLAR_EMAIL=me@x.org pd pdf 10.1/fail; N2="$(pdr):$(scu 'pub.example.org/f.pdf')"
pd pdf arxiv:2005.11401; N3="$(pdr)"
check "scholar pdf nothing found: exit 2 'missing', per-candidate reasons (HTTP code, curl failure 000, not a PDF), a URL is never tried twice, no file in the PDF folder" "$N1|$N2|$N3|$(ls "$LIT2/pdfs" | tr '\n' ' ')" "2:missing none2020 (listed in article/literature/missing.md)|:note: Unpaywall HTTP 404|tried https://pub.example.org/n.html: not a PDF|:3:2:1|2:missing fail2020 (listed in article/literature/missing.md)|:tried https://pub.example.org/f.pdf: HTTP 000|tried https://repo.example.org/f.pdf: HTTP 500|:4:1|2:missing okafor2020rag (listed in article/literature/missing.md)|:tried https://arxiv.org/pdf/2005.11401: HTTP 404|:1|brandt2017attention.pdf html2020.pdf oa2020.pdf pub2020.pdf "
MEXP="$(printf 'key\tid\ttitle\tpdf\tsource\nbrandt2017attention\tarxiv:1706.03762\tAttention is all you need\toa\thttps://arxiv.org/pdf/1706.03762\noa2020\tdoi:10.1/oaonly\t-\toa\thttps://oa.example.org/o.pdf\npub2020\tdoi:10.1/pub\tPub paper\toa\thttps://pub.example.org/p.pdf\nhtml2020\tdoi:10.1/html\tHtml first\toa\thttps://repo.example.org/h.pdf\nnone2020\tdoi:10.1/none\tNothing | here, at all\tmissing\t-\nfail2020\tdoi:10.1/fail\tFails\tmissing\t-\nokafor2020rag\tarxiv:2005.11401\tRAG\tmissing\t-\n')"
MDEXP="$(printf '# PDFs to download by hand\n\nSave each PDF in article/literature/pdfs/ with exactly the file name shown, then run: scholar.sh pdfs\n\n| File name | Title | Link |\n|---|---|---|\n| none2020.pdf | Nothing \\| here, at all | https://doi.org/10.1/none |\n| fail2020.pdf | Fails | https://doi.org/10.1/fail |\n| okafor2020rag.pdf | RAG | https://arxiv.org/abs/2005.11401 |\n')"
pd pdf 10.1/none; pd pdf 10.48550/arXiv.2005.11401
check "scholar manifest/missing.md: header, rows in order, titles cleaned (braces, spaces, tabs), arXiv DOI -> arxiv id, in-place replace on rerun (no duplicate), missing table with escaped '|' and links" "$([ "$(cat "$LIT2/manifest.tsv")" = "$MEXP" ] && echo same || echo differs):$([ "$(cat "$LIT2/missing.md")" = "$MDEXP" ] && echo same || echo differs)" "same:same"
echo x > "$W2/mark"; find "$W2" -type f -not -path '*/.git/*' | sed "s#$W2/##" | sort | tr '\n' ' ' > "$SCH/tree0"
for a in 10.9/none openalex:W12 "doi:10.1/evil" noid x; do pd pdf "$a"; PR="${PR:-}$(pdr)|"; done
pd pdf; PR="$PR$(pdr)|"; pd pdf 10.1/pub --bib "$W2/nofile.bib"; PR="$PR$(pdr)|"; mkdir -p "$W2/dirbib"; pd pdf 10.1/pub --bib "$W2/dirbib"; PR="$PR$(pdr)|"
PWD2="$TMP" pd pdf 10.1/pub; PR="$PR$(pdr)|"; PWD2="$TMP" pd pdfs; PR="$PR$(pdr)|"; pd pdf 10.1/pub 10.1/html; PR="$PR$(pdr)|"
find "$W2" -type f -not -path '*/.git/*' | sed "s#$W2/##" | sort | tr '\n' ' ' > "$SCH/tree1"
check "scholar pdf refusals: not in the .bib, openalex id, key unusable as a file name, no .bib / directory .bib, outside git, bad arguments -> exit 1, no network call, nothing written" "$PR$([ "$(cat "$SCH/tree0")" = "$(cat "$SCH/tree1")" ] && echo untouched || echo CHANGED)" "1::scholar.sh: 10.9/none is not in $W2R/article/refs.bib; add it first: scholar.sh bibtex 10.9/none --add|:0|1::scholar.sh: pdf needs a DOI or an arXiv id|:0|1::scholar.sh: the key 'a/../b' cannot be used as a file name|:0|1::scholar.sh: unrecognized identifier 'noid' (use doi:<doi> or arxiv:<id>)|:0|1::scholar.sh: unrecognized identifier 'x' (use doi:<doi> or arxiv:<id>)|:0|1::scholar.sh: pdf needs exactly one identifier|:0|1::scholar.sh: $W2/nofile.bib not found|:0|1::scholar.sh: $W2/dirbib is not a regular file|:0|1::scholar.sh: not in a git repository|:0|1::scholar.sh: not in a git repository|:0|1::scholar.sh: pdf needs exactly one identifier|:0|untouched"
mkdir -p "$LIT2/pdfs"; pdfbody 2000 > "$LIT2/pdfs/none2020.pdf"; cp "$LIT2/manifest.tsv" "$SCH/m.before"
pd pdf 10.1/none; D1="$(pdr):$(grep '^none2020' "$LIT2/manifest.tsv" | cut -f4,5 | tr '\t' '~'):$(grep -c none2020 "$LIT2/missing.md" || true)"
pd pdf 10.1/oaonly; D2="$(pdr):$(grep '^oa2020' "$LIT2/manifest.tsv" | cut -f4,5 | tr '\t' '~')"
{ printf '<html>'; head -c 4000 /dev/zero | tr '\0' a; } > "$LIT2/pdfs/fail2020.pdf"; cp "$LIT2/pdfs/fail2020.pdf" "$SCH/fail.keep"
SCHOLAR_EMAIL=me@x.org pd pdf 10.1/fail; D3="$(pdr):$(cmp -s "$LIT2/pdfs/fail2020.pdf" "$SCH/fail.keep" && echo kept || echo changed)"
{ printf '%%PDF-'; head -c 1019 /dev/zero | tr '\0' a; } > "$LIT2/pdfs/fail2020.pdf"; SCHOLAR_EMAIL=me@x.org pd pdf 10.1/fail; D4="$(cat "$SCH/rc"):$(wc -c < "$LIT2/pdfs/fail2020.pdf" | tr -d ' ')"
check "scholar pdf already present: valid dropped file -> 'present', no call, row manual with source '-', off the missing list; oa row keeps its source; invalid (HTML or exactly 1024 bytes) file is not a PDF and is left on failure" "$D1|$D2|$D3|$D4" "0:present none2020 article/literature/pdfs/none2020.pdf|::0:manual~-:0|0:present oa2020 article/literature/pdfs/oa2020.pdf|::0:oa~https://oa.example.org/o.pdf|2:missing fail2020 (listed in article/literature/missing.md)|:tried https://pub.example.org/f.pdf: HTTP 000|tried https://repo.example.org/f.pdf: HTTP 500|:4:kept|2:1024"
printf '<html>old</html>' > "$LIT2/pdfs/via2020.pdf"; date +%s > "$SCH/state/orca-roles-scholar-arxiv.last"; T0="$(date +%s)"
SCHOLAR_ARXIV_DELAY=2 SCHOLAR_EMAIL=me@x.org pd pdf 10.1/viaarxiv; X1="$(pdr):$(scg 'User-Agent: orca-roles-scholar (mailto:me@x.org)$' "$SCH/log.ua"):$(scg 'User-Agent: orca-roles-scholar$' "$SCH/log.ua"):$(( $(date +%s) - T0 >= 1 ? 1 : 0 )):$(cmp -s "$LIT2/pdfs/via2020.pdf" "$PD/arxiv_org_pdf_1706_03762" && echo replaced || echo kept):$(grep '^via2020' "$LIT2/manifest.tsv" | cut -f4,5 | tr '\t' '~')"
echo 1000 > "$SCH/state/orca-roles-scholar-arxiv.last"; SCHOLAR_ARXIV_DELAY=2 SCHOLAR_EMAIL=me@x.org pd pdf 10.1/viaarxiv >/dev/null; rm -f "$LIT2/pdfs/via2020.pdf"; SCHOLAR_ARXIV_DELAY=2 SCHOLAR_EMAIL=me@x.org pd pdf 10.1/viaarxiv
check "scholar pdf: an arXiv download is sent with the plain User-Agent; an invalid file is replaced on success; an arXiv URL from Unpaywall (and the arXiv PDF) is paced like the arXiv API and stamps the pacing file" "$X1:$([ "$(cat "$SCH/state/orca-roles-scholar-arxiv.last")" -gt 1000 ] && echo stamped || echo nostamp)" "0:downloaded via2020 article/literature/pdfs/via2020.pdf|::2:1:1:1:replaced:oa~https://arxiv.org/pdf/1706.03762:stamped"
pdfbody 2000 > "$LIT2/pdfs/oa2020.pdf"; rm -f "$LIT2/pdfs/pub2020.pdf"
{ printf '%%PDF-'; head -c 1019 /dev/zero | tr '\0' a; } > "$LIT2/pdfs/html2020.pdf"; { printf '%%PDF-'; head -c 1020 /dev/zero | tr '\0' a; } > "$LIT2/pdfs/okafor2020rag.pdf"
cp "$W2/article/refs.bib" "$SCH/refs.keep"; rm -f "$W2/article/refs.bib"
pd pdfs; Z1="$(pdr)"; cp "$LIT2/manifest.tsv" "$SCH/m.1"; pd pdfs; Z2="$(cmp -s "$LIT2/manifest.tsv" "$SCH/m.1" && echo stable || echo moved)"
cp "$SCH/refs.keep" "$W2/article/refs.bib"
check "scholar pdfs: no network call, no .bib needed; per row key/pdf/note in manifest order; missing->manual when a valid file was dropped (1025 bytes), oa/manual->missing 'file gone' / 'not a valid PDF' (1024 bytes, HTML), source reset to '-'; idempotent" "$Z1:$Z2:$(awk -F'\t' '{print $1"~"$4"~"$5}' "$LIT2/manifest.tsv" | tr '\n' ' '):$(grep -c '^| ' "$LIT2/missing.md")" "0:key${TB}pdf${TB}note|brandt2017attention${TB}oa${TB}-|oa2020${TB}oa${TB}-|pub2020${TB}missing${TB}file gone|html2020${TB}missing${TB}not a valid PDF|none2020${TB}manual${TB}-|fail2020${TB}missing${TB}not a valid PDF|okafor2020rag${TB}manual${TB}-|via2020${TB}oa${TB}-|::0:stable:key~pdf~source brandt2017attention~oa~https://arxiv.org/pdf/1706.03762 oa2020~oa~https://oa.example.org/o.pdf pub2020~missing~- html2020~missing~- none2020~manual~- fail2020~missing~- okafor2020rag~manual~- via2020~oa~https://arxiv.org/pdf/1706.03762 :4"
# pdfs: a manifest key that cannot be a file name (path parts, spaces, empty) is not tested on disk: its row is kept as it is and the note is 'invalid key'
W4="$SCH/pw4"; rm -rf "$W4"; mkdir -p "$W4/article/literature/pdfs"; git -C "$W4" init -q; LIT4="$W4/article/literature"
pdfbody 2000 > "$LIT4/out.pdf"; pdfbody 2000 > "$LIT4/pdfs/good.pdf"
{ printf 'key\tid\ttitle\tpdf\tsource\n'; printf '../out\tdoi:10.1/a\tOut\tmissing\t-\n'; printf 'x/y\tdoi:10.1/b\tSlash\toa\thttps://x.org/y.pdf\n'; printf 'a b\tdoi:10.1/c\tSpace\tmissing\t-\n'; printf 'good\tdoi:10.1/d\tGood\tmissing\t-\n'; printf '\tdoi:10.1/e\tNo key\toa\thttps://x.org/e.pdf\n'; printf 'gone.v-1:2+3\tdoi:10.1/f\tOdd but valid\toa\thttps://x.org/f.pdf\n'; } > "$LIT4/manifest.tsv"
PWD2="$W4" pd pdfs; IK="$(pdr)"
check "scholar pdfs: invalid keys keep their row unchanged and say 'invalid key' (never tested outside pdfs/), valid keys are reconciled as before" "$IK:$(cat "$LIT4/manifest.tsv" | tr '\t\n' '~|')" "0:key${TB}pdf${TB}note|../out${TB}missing${TB}invalid key|x/y${TB}oa${TB}invalid key|a b${TB}missing${TB}invalid key|good${TB}manual${TB}-|${TB}oa${TB}invalid key|gone.v-1:2+3${TB}missing${TB}file gone|::0:key~id~title~pdf~source|../out~doi:10.1/a~Out~missing~-|x/y~doi:10.1/b~Slash~oa~https://x.org/y.pdf|a b~doi:10.1/c~Space~missing~-|good~doi:10.1/d~Good~manual~-|~doi:10.1/e~No key~oa~https://x.org/e.pdf|gone.v-1:2+3~doi:10.1/f~Odd but valid~missing~-|"
W3="$SCH/pw3"; rm -rf "$W3"; mkdir -p "$W3/article/literature"; git -C "$W3" init -q; W3R="$(cd "$W3" && pwd -P)"
PWD2="$W3" pd pdfs; M1="$(pdr)"; PWD2="$W3" pd pdfs x; M2="$(pdr)"; PWD2="$W3" pd pdfs --bib "$W2/dirbib"; M3="$(pdr)"
printf 'key\tpdf\n' > "$W3/article/literature/manifest.tsv"; printf 'k\t10\n' >> "$W3/article/literature/manifest.tsv"; cp "$W3/article/literature/manifest.tsv" "$SCH/m.foreign"
PWD2="$W3" pd pdfs; M4="$(pdr)"; PWD2="$W3" pd pdf 10.1/pub --bib "$W2/article/refs.bib"; M5="$(pdr)"
check "scholar pdfs errors: no manifest, bad arguments, foreign manifest header (pdfs and pdf refuse it) -> exit 1, no call, manifest untouched, no missing.md" "$M1|$M2|$M3|$M4|$M5|$(cmp -s "$W3/article/literature/manifest.tsv" "$SCH/m.foreign" && echo same || echo CHANGED):$(ls "$W3/article/literature" | tr '\n' ' ')" "1::scholar.sh: no manifest yet (article/literature/manifest.tsv); run scholar.sh pdf <id> first|:0|1::scholar.sh: pdfs takes no argument (got 'x')|:0|1::scholar.sh: $W2/dirbib is not a regular file|:0|1::scholar.sh: $W3R/article/literature/manifest.tsv does not start with the header (key, id, title, pdf, source)|:0|1::scholar.sh: $W3R/article/literature/manifest.tsv does not start with the header (key, id, title, pdf, source)|:0|same:manifest.tsv "
}

sec_e2e_browser() {
# bin/e2e-browser.sh with stubbed node and npm: no network, no real browser
EB="$TMP/eb"; rm -rf "$EB"; mkdir -p "$EB/bin" "$EB/pw" "$EB/stubs"
cp "$ROOT/bin/e2e-browser.sh" "$EB/bin/"; chmod +x "$EB/bin/e2e-browser.sh"
printf '{"dependencies":{"@playwright/mcp":"1.2.3","@playwright/test":"4.5.6-alpha-1"}}' > "$EB/pw/package.json"
EBX="$EB/browsers/chromium-1/chrome-linux/chrome"
printf '#!/bin/sh\necho noise\necho "$EB_EXE"\n' > "$EB/stubs/node"
printf '#!/bin/sh\necho "npm $* | PW=${PLAYWRIGHT_BROWSERS_PATH:-}" >> "$EB_LOG"\n[ -z "${EB_NPM_FAIL:-}" ]\n' > "$EB/stubs/npm"
printf '#!/bin/sh\necho "pw $* | PW=${PLAYWRIGHT_BROWSERS_PATH:-}" >> "$EB_LOG"\n[ -z "${EB_PW_FAIL:-}" ]\n' > "$EB/stubs/playwright"
printf '#!/bin/sh\necho Linux\n' > "$EB/stubs/uname"
chmod +x "$EB/stubs/"*
eb_ver() { mkdir -p "$EB/pw/node_modules/$1"; printf '{"version":"%s"}' "$2" > "$EB/pw/node_modules/$1/package.json"; }
eb_full() {
  eb_ver @playwright/mcp 1.2.3; eb_ver @playwright/test 4.5.6-alpha-1; mkdir -p "$EB/pw/node_modules/playwright-core" "$EB/pw/node_modules/.bin" "${EBX%/*}"
  cp "$EB/stubs/playwright" "$EB/pw/node_modules/.bin/playwright"; printf '#!/bin/sh\n' > "$EBX"; chmod +x "$EBX"; : > "$EB/browsers/chromium-1/INSTALLATION_COMPLETE"
}
eb() { : > "$EB/log"; if OUT="$(KIT="$EB" E2E_NODE="$EB/stubs/node" E2E_NPM="$EB/stubs/npm" EB_EXE="$EBX" EB_LOG="$EB/log" PATH="$EB/stubs:$PATH" "$EB/bin/e2e-browser.sh" "$@" 2>&1)"; then RC=0; else RC=$?; fi; }
# a bare uname stub would make every call think it is Linux: only the Linux cases put the stubs dir first
eb_mac() { : > "$EB/log"; mkdir -p "$EB/macpath"; if OUT="$(KIT="$EB" E2E_NODE="$EB/stubs/node" E2E_NPM="$EB/stubs/npm" EB_EXE="$EBX" EB_LOG="$EB/log" "$EB/bin/e2e-browser.sh" "$@" 2>&1)"; then RC=0; else RC=$?; fi; }
eb_mac check
check "e2e-browser check: empty tree -> exit 2, lists what is missing, prints the install command" "$RC:$(printf '%s\n' "$OUT" | grep -c 'not installed'):$(printf '%s\n' "$OUT" | grep -c "^Fix: $EB/bin/e2e-browser.sh install$")" "2:3:1"
eb_full; eb_mac check
check "e2e-browser check: complete tree -> exit 0 and the executable path" "$RC:$OUT" "0:E2E browser ready: $EBX"
eb_ver @playwright/mcp 1.2.4; eb_mac check
check "e2e-browser check: a different mcp version than the pin -> exit 2 naming both" "$RC:$(printf '%s\n' "$OUT" | grep -c 'is 1.2.4 .* pins 1.2.3')" "2:1"
eb_ver @playwright/mcp 1.2.3; eb_ver @playwright/test 4.5.6; eb_mac check
check "e2e-browser check: a different test version than the pin -> exit 2" "$RC:$(printf '%s\n' "$OUT" | grep -c 'is 4.5.6 .* pins 4.5.6-alpha-1')" "2:1"
eb_ver @playwright/test 4.5.6-alpha-1
chmod -x "$EBX"; eb_mac check
check "e2e-browser check: Chromium not executable -> exit 2" "$RC:$(printf '%s\n' "$OUT" | grep -c 'Chromium is not installed')" "2:1"
chmod +x "$EBX"; rm "$EB/browsers/chromium-1/INSTALLATION_COMPLETE"; eb_mac check
check "e2e-browser check: INSTALLATION_COMPLETE missing -> exit 2 naming the marker" "$RC:$(printf '%s\n' "$OUT" | grep -c 'INSTALLATION_COMPLETE is missing')" "2:1"
: > "$EB/browsers/chromium-1/INSTALLATION_COMPLETE"
eb check
check "e2e-browser check on Linux, ready: no install-deps output" "$RC:$(grep -c install-deps "$EB/log")" "0:0"
rm "$EB/browsers/chromium-1/INSTALLATION_COMPLETE"; eb check
check "e2e-browser check on Linux, not ready: install-deps only as --dry-run, the sudo command only printed" "$RC:$(grep -c '^pw install-deps --dry-run chromium' "$EB/log"):$(grep -c 'install-deps' "$EB/log"):$(printf '%s\n' "$OUT" | grep -c "sudo $EB/pw/node_modules/.bin/playwright install-deps chromium")" "2:1:1:1"
: > "$EB/browsers/chromium-1/INSTALLATION_COMPLETE"
eb_mac bogus; check "e2e-browser: unknown argument -> exit 1 with the usage" "$RC:$(printf '%s\n' "$OUT" | grep -c '^# Usage\|^Usage')" "1:1"
eb_mac install
check "e2e-browser install: npm ci --prefix the tree, then playwright install --no-shell chromium into the kit browsers, no sudo, ends with check" "$RC:$(sed -n 1p "$EB/log"):$(sed -n 2p "$EB/log"):$(grep -c sudo "$EB/log"):$(printf '%s\n' "$OUT" | tail -1)" "0:npm ci --prefix $EB/pw | PW=$EB/browsers:pw install --no-shell chromium | PW=$EB/browsers:0:E2E browser ready: $EBX"
EB_NPM_FAIL=1 eb_mac install
check "e2e-browser install: a failing npm ci stops there, exit 1, ERROR on output" "$RC:$(grep -c '^pw ' "$EB/log"):$(printf '%s\n' "$OUT" | grep -c 'ERROR: npm ci failed')" "1:0:1"
EB_PW_FAIL=1 eb_mac install
check "e2e-browser install: a failing browser install -> exit 1, ERROR on output, no 'ready'" "$RC:$(printf '%s\n' "$OUT" | grep -c 'ERROR: playwright install chromium failed'):$(printf '%s\n' "$OUT" | grep -c 'E2E browser ready')" "1:1:0"

# session: reads the saved state, starts nothing; every exit code with its boundaries
cp "$ROOT/bin/lib.sh" "$EB/bin/"; SNOW="$(date +%s)"; SF1=$((SNOW+1000)); SF2=$((SNOW+5000)); SPAST=$((SNOW-1000))
ebs_state() { mkdir -p "$EB/browser/p"; printf '%s' "$1" > "$EB/browser/p/${2:-default}.json"; }
ck() { printf '{"name":"s","value":"v","domain":"%s","path":"/","expires":%s}' "$1" "$2"; }
rm -rf "$EB/browser"; eb session http://app.example.com p
S1="$RC"; ebs_state '{"cookies":[],"origins":[]}'; eb session http://app.example.com p; S2="$RC"; ebs_state '{not json'; eb session http://app.example.com p
check "e2e-browser session: no file, empty stub and invalid JSON -> 3 missing, each with the login command" "$S1:$S2:$RC:$(printf '%s\n' "$OUT" | grep -c '^missing')" "3:3:3:1"
ebs_state "{\"cookies\":[$(ck .example.com $SF2),$(ck .example.com $SF1),$(ck .example.com $SPAST)],\"origins\":[]}"; eb session http://app.example.com p
S1="$RC:$(printf '%s\n' "$OUT" | grep -c "^ok: session for http://app.example.com saved .*; earliest cookie expiry $(date -u -r "$SF1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$SF1" +%Y-%m-%dT%H:%M:%SZ || true)\$"):$(printf '%s\n' "$OUT" | grep -c '^Login' || true)"
eb session http://example.com p; S2="$RC"; ebs_state "{\"cookies\":[$(ck app.example.com $SF1)],\"origins\":[]}"; eb session http://APP.example.com p
check "e2e-browser session: leading-dot cookie matches subdomain and apex, exact domain matches its host; ok names the earliest live expiry, skips the expired one, prints no login line" "$S1:$S2:$RC" "0:1:0:0:0"
ebs_state "{\"cookies\":[$(ck app.example.com $SF1)],\"origins\":[]}"; eb session http://www.example.com p; S1="$RC"
ebs_state "{\"cookies\":[$(ck .example.com $SF1)],\"origins\":[]}"; eb session http://badexample.com p; S2="$RC"; eb session http://other.org p
check "e2e-browser session: a host-only cookie does not match a sibling, a leading-dot domain not a lookalike suffix nor another host -> 4 no-session-for-host" "$S1:$S2:$RC:$(printf '%s\n' "$OUT" | grep -c '^no-session-for-host')" "4:4:4:1"
ebs_state "{\"cookies\":[$(ck .example.com $SPAST),$(ck .example.com "$SNOW")],\"origins\":[]}"; eb session http://app.example.com p; S1="$RC:$(printf '%s\n' "$OUT" | grep -c '^expired' || true)"
ebs_state "{\"cookies\":[$(ck .example.com $SPAST),$(ck .example.com -1)],\"origins\":[]}"; eb session http://app.example.com p; S2="$RC"
ebs_state "{\"cookies\":[$(ck .example.com -1)],\"origins\":[]}"; eb session http://app.example.com p
check "e2e-browser session: all persistent cookies expired (also just now, and next to a session cookie) -> 5; only session cookies -> 6 unknown" "$S1:$S2:$RC:$(printf '%s\n' "$OUT" | grep -c '^unknown')" "5:1:5:6:1"
LS='{"origin":"http://localhost:3000","localStorage":[{"name":"t","value":"x"}]}'
ebs_state "{\"cookies\":[],\"origins\":[$LS]}"; eb session http://localhost:3000 p; S1="$RC:$(printf '%s\n' "$OUT" | grep -c 'no persistent cookie, localStorage for the origin' || true)"
eb session http://localhost:3001 p; S2="$RC"; eb session https://localhost:3000 p; S3="$RC"
ebs_state '{"cookies":[],"origins":[{"origin":"https://app.example.com","localStorage":[{"name":"t","value":"x"}]}]}'; eb session https://app.example.com:443 p; S4="$RC"
ebs_state '{"cookies":[],"origins":[{"origin":"http://localhost:3000","localStorage":[]}]}'; eb session http://localhost:3000 p; S5="$RC"
ebs_state '{"cookies":[],"origins":[{"origin":"https://APP.example.com:443","localStorage":[{"name":"t","value":"x"}]}]}'; eb session https://app.example.com p; S6="$RC"
ebs_state "{\"cookies\":[$(ck localhost $SPAST)],\"origins\":[$LS]}"; eb session http://localhost:3000 p
check "e2e-browser session: localStorage counts only for the exact origin (port, scheme), a default port is normalised, an empty localStorage array counts for nothing, localStorage beats expired cookies" "$S1:$S2:$S3:$S4:$S5:$S6:$RC" "0:1:4:4:0:4:0:0"
ebs_state "{\"cookies\":[$(ck localhost $SF1)],\"origins\":[]}"; eb session http://localhost:3000 p --as admin; S1="$RC:$(printf '%s\n' "$OUT" | grep -c 'identity .admin.' || true)"
ebs_state "{\"cookies\":[$(ck localhost $SF1)],\"origins\":[]}" admin; eb session http://localhost:3000 p --as admin; S2="$RC"
check "e2e-browser session: --as reads that identity's file (missing for admin until saved)" "$S1:$S2" "3:1:0"
rm -rf "$EB/browser"; eb session http://localhost:3000 p; S1="$(printf '%s\n' "$OUT" | grep '^Login:')"; eb session http://localhost:3000 p --as admin; S2="$(printf '%s\n' "$OUT" | grep '^Login:')"
eb session http://localhost:3000 --as qa; S3="$(printf '%s\n' "$OUT" | grep '^Login:')"
check "e2e-browser session: the login command is exact (project only if given, --as omitted for default)" "$S1|$S2|$S3" 'Login: ~/.orca-roles/bin/browser-login.sh http://localhost:3000 p|Login: ~/.orca-roles/bin/browser-login.sh http://localhost:3000 p --as admin|Login: ~/.orca-roles/bin/browser-login.sh http://localhost:3000 --as qa'
eb session http://localhost:3000 p --as Bad_Id; S1="$RC"; eb session localhost:3000 p; S2="$RC"; eb session; S3="$RC"; eb session http://localhost:3000 p --as; S4="$RC"; eb session http://localhost:3000 p extra; S5="$RC"; : > "$EB/log"; eb session http://localhost:3000 p
check "e2e-browser session: invalid identity, URL without http(s), no URL, --as without value, extra argument -> 1; it starts no node, npm or playwright" "$S1:$S2:$S3:$S4:$S5:$(wc -c < "$EB/log" | tr -d ' ')" "1:1:1:1:1:0"
}

sec_browser_login() {
# session_file, migrate_session and bin/browser-login.sh with a fake playwright and a stubbed stack check: no browser, no network
BL="$TMP/bl"; rm -rf "$BL"; mkdir -p "$BL/bin" "$BL/pw/node_modules/.bin" "$BL/stubs"
cp "$ROOT/bin/lib.sh" "$ROOT/bin/browser-login.sh" "$BL/bin/"
printf '#!/bin/sh\n[ "${BL_CHECK_RC:-0}" = 0 ] && { echo "E2E browser ready: x"; exit 0; }\necho "E2E browser: not installed"; echo "Fix: $0 install"; exit "$BL_CHECK_RC"\n' > "$BL/bin/e2e-browser.sh"
cat > "$BL/pw/node_modules/.bin/playwright" <<'PWEOF'
#!/bin/sh
echo "$* | PW=${PLAYWRIGHT_BROWSERS_PATH:-}" >> "$BL_LOG"
out=""; for a in "$@"; do case "$a" in --save-storage=*) out="${a#--save-storage=}";; esac; done
case "${BL_MODE:-valid}" in
  valid) echo '{"cookies":[{"name":"a","domain":"u"},{"name":"b","domain":"u"}],"origins":[{"origin":"o"}]}' > "$out";;
  validfail) echo '{"cookies":[{"name":"a","domain":"u"}],"origins":[]}' > "$out"; exit 1;;
  other) echo '{"cookies":[{"name":"a","domain":"other.test"}],"origins":[{"origin":"http://other.test","localStorage":[{"name":"k","value":"v"}]}]}' > "$out";;
  empty) echo '{"cookies":[],"origins":[]}' > "$out";;
  nokeys) echo '{}' > "$out";;
  garbage) echo 'not json' > "$out";;
  fail) exit 1;;
esac
PWEOF
printf '#!/bin/sh\necho "npx $*" >> "$BL_LOG"\n' > "$BL/stubs/npx"
chmod +x "$BL/bin/"*.sh "$BL/pw/node_modules/.bin/playwright" "$BL/stubs/npx"
BL_LOG="$BL/log"; BLERR="$BL/err"; BLS="$BL/browser/p/default.json"
OLD='{"cookies":[{"name":"old"}],"origins":[]}'
bl() { : > "$BL_LOG"; if OUT="$(cd "$PROJ" && KIT="$BL" BL_LOG="$BL_LOG" PATH="$BL/stubs:$PATH" "$BL/bin/browser-login.sh" "$@" 2> "$BLERR")"; then RC=0; else RC=$?; fi; }
# the old single file <project>.json and the destination content ($2, absent = no destination) -> "destination:old file state:stderr lines"
mig() { rm -rf "$BL/browser"; mkdir -p "$BL/browser/p"; printf '%s' "$1" > "$BL/browser/p.json"; [ -z "${2+x}" ] || printf '%s' "$2" > "$BLS"
  ( KIT="$BL"; . "$BL/bin/lib.sh"; migrate_session p 2> "$BLERR" ); echo "$(cat "$BLS" 2>/dev/null):$(test -e "$BL/browser/p.json" && echo old-kept || echo old-gone):$(wc -l < "$BLERR" | tr -d ' ')"; }
( KIT="$BL"; . "$BL/bin/lib.sh"
  ok="$(for i in default a 0 a-b a1-2 9x; do session_file p "$i" >/dev/null 2>&1 && printf y; done)"
  bad="$(for i in Bad_ID -x '' a/b a.b Admin ../x 'a b' -; do if session_file p "$i" >/dev/null 2>&1; then printf y; else printf n; fi; done)"
  check "session_file: <project>/<identity>.json, default identity, only [a-z0-9][a-z0-9-]* accepted, refusal names the rule" "$(session_file p):$(session_file p a-1):$ok:$bad:$(session_file p Bad 2>&1 >/dev/null | grep -c 'invalid identity')" "$BL/browser/p/default.json:$BL/browser/p/a-1.json:yyyyyy:nnnnnnnnn:1"
  [ "$FAIL" = 0 ] ) || FAIL=1
check "migrate_session: old file only (or an old file holding {}) -> moved to <project>/default.json, no warning" "$(mig "$OLD")|$(mig '{}')" "$OLD:old-gone:0|{}:old-gone:0"
check "migrate_session: empty stub or key-less destination -> replaced by the old file, no warning" "$(mig "$OLD" '{"cookies":[],"origins":[]}')|$(mig "$OLD" '{}')" "$OLD:old-gone:0|$OLD:old-gone:0"
NEWC='{"cookies":[{"name":"new"}],"origins":[]}'; NEWO='{"cookies":[],"origins":[{"origin":"o"}]}'
R1="$(mig "$OLD" "$NEWC")"; W1="$(grep -c "WARNING.*$BL/browser/p.json.*$BL/browser/p/default.json" "$BLERR" || true)"
check "migrate_session: a destination with cookies, with origins only or unreadable is never overwritten: old kept, one warning naming both files" "$R1:$W1|$(mig "$OLD" "$NEWO")|$(mig "$OLD" 'not json')" "$NEWC:old-kept:1:1|$NEWO:old-kept:1|not json:old-kept:1"
rm -rf "$BL/browser"; mkdir -p "$BL/browser"; printf '%s' "$OLD" > "$BL/browser/proj.json"
echo '{"roles":{"x":{}}}' > "$BL/cfg.json"
( KIT="$BL"; . "$BL/bin/lib.sh"; role_context "$BL/cfg.json" x "$PROJ"
  check "role_context: migrates browser/<project>.json into the default identity's file and points the MCP state at it" "$ORCA_ROLES_BROWSER_STATE:$(cat "$BL/browser/proj/default.json" 2>/dev/null):$(test -e "$BL/browser/proj.json" && echo old-kept || echo old-gone)" "$BL/browser/proj/default.json:$OLD:old-gone"
  [ "$FAIL" = 0 ] ) || FAIL=1
rm -rf "$BL/browser"
bl http://u p
check "browser-login: valid save -> exit 0, default.json written, counts printed, pinned binary with the kit browsers, temp file gone, no npx" "$RC:$(jq -c '[(.cookies|length),(.origins|length)]' "$BLS"):$(printf '%s\n' "$OUT" | grep -c '^Session saved: 2 cookies, 1 origins\.$'):$(printf '%s\n' "$OUT" | grep -c '^Identity: default$'):$(sed 's#--save-storage=[^ ]*#SAVE#' "$BL_LOG"):$(ls "$BL/browser/p" | tr '\n' ' ')" "0:[2,1]:1:1:open SAVE http://u | PW=$BL/browsers:default.json "
bl http://u p --as admin; A1="$RC:$(ls "$BL/browser/p" | tr '\n' ' ')"; rm -f "$BL/browser/p/admin.json"
bl http://u --as admin p; A2="$RC:$(ls "$BL/browser/p" | tr '\n' ' '):$(printf '%s\n' "$OUT" | grep -c '^Project: p$')"; rm -f "$BL/browser/p/admin.json"
bl http://u --as admin; A3="$RC:$(ls "$BL/browser/proj" | tr '\n' ' ')"
check "browser-login: --as before or after the positional project (or alone, project from the repo) saves <project>/<identity>.json and leaves default.json" "$A1|$A2|$A3" "0:admin.json default.json |0:admin.json default.json :1|0:admin.json "
rm -rf "$BL/browser"; BADN="$(for i in Bad_ID -x a/b ../x Admin ""; do bl http://u p --as "$i"; printf '%s:%s:%s:%s;' "$RC" "$(grep -c 'invalid identity' "$BLERR")" "$(wc -l < "$BL_LOG" | tr -d ' ')" "$(test -e "$BL/browser" && echo made || echo none)"; done)"
bl http://u p --as; BADN="$BADN$RC:$(grep -c -- '--as needs' "$BLERR")"
check "browser-login: invalid identities (also an empty one) and a bare --as -> exit 1 with the message, playwright never run, nothing created" "$BADN" "1:1:0:none;1:1:0:none;1:1:0:none;1:1:0:none;1:1:0:none;1:1:0:none;1:1"
rm -rf "$BL/browser"; FS=""; for m in empty nokeys garbage fail; do mkdir -p "$BL/browser/p"; printf '%s' "$OLD" > "$BLS"; BL_MODE=$m bl http://u p; FS="$FS$m=$RC:$(cat "$BLS"):$(printf '%s\n' "$OUT" "$(cat "$BLERR")" | grep -c '^Nothing was saved'):$(grep -c 'previous session.*unchanged' "$BLERR"):$(ls "$BL/browser/p" | tr '\n' ' ');"; done
check "browser-login: empty stub, {}, invalid JSON or a failing playwright -> exit 1, previous session byte-identical, 'Nothing was saved' + 'unchanged', no temp file" "$FS" "empty=1:$OLD:1:1:default.json ;nokeys=1:$OLD:1:1:default.json ;garbage=1:$OLD:1:1:default.json ;fail=1:$OLD:1:1:default.json ;"
rm -rf "$BL/browser"; FN=""; for m in empty garbage fail; do BL_MODE=$m bl http://u p; FN="$FN$m=$RC:$(grep -c 'Nothing was saved' "$BLERR"):$(grep -c 'unchanged' "$BLERR"):$(ls "$BL/browser/p" 2>/dev/null | wc -l | tr -d ' ');"; done
check "browser-login: failed save with no previous session -> exit 1, no default.json, no 'unchanged' claim" "$FN" "empty=1:1:0:0;garbage=1:1:0:0;fail=1:1:0:0;"
rm -rf "$BL/browser"; mkdir -p "$BL/browser/p"; printf '%s' "$OLD" > "$BL/browser/p.json"; BL_MODE=fail bl http://u p
M1="$RC:$(cat "$BLS" 2>/dev/null)"; rm -rf "$BL/browser"; BL_MODE=validfail bl http://u p
check "browser-login: migrates the old file before opening; a failing exit status does not matter when the file is valid" "$M1|$RC:$(jq -c '.cookies|length' "$BLS")" "1:$OLD|0:1"
rm -rf "$BL/browser"; mkdir -p "$BL/browser/p"; printf '%s' "$OLD" > "$BLS"; BL_MODE=other bl http://u p; XS="$RC:$(cmp -s "$BLS" <(printf '%s' "$OLD") && echo same || echo changed):$(grep -c '^Nothing was saved for u: the browser stored no cookie for that host' "$BLERR"):$(grep -c 'previous session.*unchanged' "$BLERR"):$(ls "$BL/browser/p" | tr '\n' ' ')"
rm -rf "$BL/browser"; BL_MODE=other bl http://u p; XN="$RC:$(grep -c 'Nothing was saved for u:' "$BLERR"):$(grep -c unchanged "$BLERR"):$(ls "$BL/browser/p" 2>/dev/null | wc -l | tr -d ' ')"
BL_MODE=other bl http://other.test p; XO="$RC:$(jq -c '.cookies|length' "$BLS")"; rm -rf "$BL/browser"; BL_MODE=other bl http://localhost:3000 p; XP="$RC:$(ls "$BL/browser/p" 2>/dev/null | wc -l | tr -d ' ')"
check "browser-login: a session with cookies only for another host is refused (previous file byte-identical, message names the host), saved when the URL is that host" "$XS|$XN|$XO|$XP" "1:same:1:1:default.json |1:1:0:0|0:1|1:0"
MT="$BL/mt.json"; SM=""; smt() { printf '%s' "$1" > "$MT"; if ( KIT="$BL"; . "$BL/bin/lib.sh"; session_matches "$MT" "$2" ); then SM="${SM}y"; else SM="${SM}n"; fi; }
smt '{"cookies":[{"domain":"app.example.com"}]}' https://app.example.com/x
smt '{"cookies":[{"domain":"app.example.com"}]}' https://APP.Example.COM:443/x
smt '{"cookies":[{"domain":"app.example.com"}]}' https://example.com
smt '{"cookies":[{"domain":"app.example.com"}]}' https://x.app.example.com
smt '{"cookies":[{"domain":".example.com"}]}' https://app.example.com
smt '{"cookies":[{"domain":".example.com"}]}' https://example.com
smt '{"cookies":[{"domain":".example.com"}]}' https://badexample.com
smt '{"cookies":[{"domain":".example.com"}]}' https://example.com.evil.test
smt '{"cookies":[{"name":"nodomain"}]}' https://example.com
smt '{"cookies":[],"origins":[{"origin":"http://localhost:3000","localStorage":[{"name":"a","value":"b"}]}]}' http://localhost:3000/app
smt '{"cookies":[],"origins":[{"origin":"http://localhost:3000","localStorage":[{"name":"a","value":"b"}]}]}' http://localhost:3001
smt '{"cookies":[],"origins":[{"origin":"http://localhost:3000","localStorage":[]}]}' http://localhost:3000
smt '{"cookies":[],"origins":[{"origin":"http://h:80","localStorage":[{"name":"a","value":"b"}]}]}' http://h
smt '{"cookies":[],"origins":[{"origin":"https://h:443","localStorage":[{"name":"a","value":"b"}]}]}' https://H:443
smt '{"cookies":[{"domain":"example.com"}]}' ftp://example.com
smt '{"cookies":[{"domain":"example.com"}]}' example.com
smt '{"cookies":[{"domain":"example.com"}]}' http://
smt 'not json' http://example.com
smt '{"cookies":[{"domain":"example.com"}]}' http://user:pw@example.com:8080/p
check "session_matches: exact host, case and default port, subdomain of a host-only cookie no, dot-domain matches host and subdomains but not look-alikes, localStorage by normalized origin (port, non-empty), non-http URL, bad JSON" "$SM" "yynnyynnnynnyynnnny"
rm -rf "$BL/browser"; BL_CHECK_RC=2 bl http://u p; C1="$RC:$(printf '%s\n' "$OUT" "$(cat "$BLERR")" | grep -c 'not installed'):$(wc -l < "$BL_LOG" | tr -d ' '):$(test -e "$BL/browser" && echo made || echo none)"
rm "$BL/pw/node_modules/.bin/playwright"; bl http://u p; C2="$RC:$(grep -c 'missing' "$BLERR"):$(wc -l < "$BL_LOG" | tr -d ' ')"
check "browser-login: stack check failing or binary missing -> exit 2 with the message, nothing opened, no npx; the script has no bare npx playwright" "$C1|$C2|$(grep -c 'npx' "$ROOT/bin/browser-login.sh")" "2:1:0:none|2:1:0|0"
}


sec_e2e_run() {
# bin/e2e-run.sh with a fake playwright binary and a stubbed stack check: no browser, no network, a scratch kit
set +e   # a mutant makes some greps count 0: report it as a FAIL line instead of ending the script
ER="$TMP/er"; rm -rf "$ER"; mkdir -p "$ER/kit/bin" "$ER/kit/pw/node_modules/.bin" "$ER/kit/browser/proj" "$ER/proj"
cp "$ROOT/bin/e2e-run.sh" "$ROOT/bin/lib.sh" "$ER/kit/bin/"; cp "$ROOT/config.default.json" "$ER/kit/"
printf '#!/bin/sh\n[ "${ER_CHECK_RC:-0}" = 0 ] && { echo "E2E browser ready: x"; exit 0; }\necho "E2E browser: not installed"; echo "Fix: install"; exit "$ER_CHECK_RC"\n' > "$ER/kit/bin/e2e-browser.sh"
cat > "$ER/kit/pw/node_modules/.bin/playwright" <<'PWEOF'
#!/bin/sh
{ printf 'ARGS=%s\n' "$*"; for v in E2E_FLOW_DIR E2E_EVIDENCE_DIR E2E_TIMEOUT_MS E2E_PARAMS E2E_STORAGE_STATE PLAYWRIGHT_BROWSERS_PATH; do eval "printf '%s=%s\\n' $v \"\${$v-UNSET}\""; done; } > "$ER_LOG"
[ -z "${ER_RESULT:-}" ] || echo '[]' > "$E2E_EVIDENCE_DIR/result.json"
exit "${ER_PW_RC:-0}"
PWEOF
chmod +x "$ER/kit/bin/"*.sh "$ER/kit/pw/node_modules/.bin/playwright"
git -C "$ER/proj" init -q; ERL="$ER/log"; ERK="$ER/kit"; ERW="$(cd "$ER/proj" && pwd -P)"
mkdir -p "$ERW/qa-e2e/one" "$ERW/qa-e2e/three/sub" "$ERW/qa-e2e/none"
touch "$ERW/qa-e2e/one/a.flow.ts" "$ERW/qa-e2e/three/a.flow.ts" "$ERW/qa-e2e/three/b.flow.js" "$ERW/qa-e2e/three/c.flow.ts" "$ERW/qa-e2e/three/d.txt" "$ERW/qa-e2e/three/e.flow.ts.bak" "$ERW/qa-e2e/three/sub/f.flow.ts" "$ERW/qa-e2e/none/x.spec.ts"
er() { : > "$ERL"; if OUT="$(cd "$ERW" && KIT="$ERK" ER_LOG="$ERL" "$ERK/bin/e2e-run.sh" "$@" 2>&1)"; then RC=0; else RC=$?; fi; }
erv() { grep "^$1=" "$ERL" | head -1 | cut -d= -f2-; }
erran() { [ -s "$ERL" ] && echo ran || echo not-run; }
erlink() { [ -L "$ERW/qa-e2e/node_modules" ] && readlink "$ERW/qa-e2e/node_modules" || echo nolink; }
ERS="$ERK/browser/proj/default.json"; ERA="$ERK/browser/proj/admin.json"; ERFULL='{"cookies":[{"name":"a"}],"origins":[]}'

BAD=""; for f in nope none ../one .hid a/b 'a b' 'one;x' qa-e2e/one; do er "$f"; BAD="$BAD$RC:$(erran):$(erlink);"; done
er; BAD="$BAD$RC:$(erran);"; er one two; BAD="$BAD$RC:$(erran);"; er one --bogus; BAD="$BAD$RC:$(erran)"
check "e2e-run: missing flow, no *.flow file (only a spec, nothing), path-like or odd names, no flow, two flows, unknown option -> exit 1, playwright never run, no link made" "$BAD" "1:not-run:nolink;1:not-run:nolink;1:not-run:nolink;1:not-run:nolink;1:not-run:nolink;1:not-run:nolink;1:not-run:nolink;1:not-run:nolink;1:not-run;1:not-run;1:not-run"
ER_CHECK_RC=2 er one; S1="$RC:$(erran):$(erlink):$(printf '%s\n' "$OUT" | grep -c 'not installed')"
ER_CHECK_RC=7 er one; check "e2e-run: stack not ready -> exit 2 with the check's message (whatever its status), playwright not run, nothing linked" "$S1|$RC:$(erran):$(erlink)" "2:not-run:nolink:1|2:not-run:nolink"

er one
HAPPY="$RC:$(erv ARGS):$(erv E2E_FLOW_DIR):$(erv E2E_EVIDENCE_DIR):$(erv E2E_TIMEOUT_MS):$(erv E2E_PARAMS):$(erv E2E_STORAGE_STATE):$(erv PLAYWRIGHT_BROWSERS_PATH)"
check "e2e-run: happy path -> the kit binary with test --config <kit>/pw/e2e.config.js --global-timeout 300000 and nothing else, env of the contract, no session, no params" "$HAPPY" "0:test --config $ERK/pw/e2e.config.js --global-timeout 300000:$ERW/qa-e2e/one:$ERW/qa-evidence/one:60000:{}::$ERK/browsers"
check "e2e-run: links qa-e2e/node_modules to the kit's tree, writes the package.json, creates the evidence dir, prints the paths (no result.json line unless the flow wrote one)" "$(erlink):$(cat "$ERW/qa-e2e/one/../package.json"):$(test -d "$ERW/qa-evidence/one" && echo evid):$(printf '%s\n' "$OUT" | grep -c "^Evidence: $ERW/qa-evidence/one\$"):$(printf '%s\n' "$OUT" | grep -c "^report.json: $ERW/qa-evidence/one/report.json\$"):$(printf '%s\n' "$OUT" | grep -c '^result.json')" "$ERK/pw/node_modules:{\"private\": true, \"type\": \"commonjs\"}:evid:1:1:0"
ER_RESULT=1 ER_PW_RC=3 er one
check "e2e-run: playwright's exit status is the script's; result.json is printed when the flow wrote it" "$RC:$(printf '%s\n' "$OUT" | grep -c "^result.json: $ERW/qa-evidence/one/result.json\$")" "3:1"

mkdir -p "$ERW/other"; ln -sfn "$ERW/other" "$ERW/qa-e2e/node_modules"; echo '{"mine":1}' > "$ERW/qa-e2e/package.json"; er one
check "e2e-run: a link to somewhere else is repointed to the kit; an existing package.json is not overwritten" "$RC:$(erlink):$(cat "$ERW/qa-e2e/package.json")" "0:$ERK/pw/node_modules:{\"mine\":1}"
rm "$ERW/qa-e2e/node_modules"; mkdir -p "$ERW/qa-e2e/node_modules/real"; echo keep > "$ERW/qa-e2e/node_modules/real/f"; er one
R1="$RC:$(erran):$(cat "$ERW/qa-e2e/node_modules/real/f"):$(test -L "$ERW/qa-e2e/node_modules" && echo link || echo dir):$(printf '%s\n' "$OUT" | grep -c 'real file or folder' || true)"
rm -rf "$ERW/qa-e2e/node_modules"; echo keep > "$ERW/qa-e2e/node_modules"; er one
check "e2e-run: a real node_modules (folder with content, or a file) is refused with exit 1, left untouched, playwright not run" "$R1|$RC:$(erran):$(cat "$ERW/qa-e2e/node_modules")" "1:not-run:keep:dir:1|1:not-run:keep"
rm -f "$ERW/qa-e2e/node_modules"

er three; G1="$(erv ARGS | sed 's/.*--global-timeout //')"; er three --timeout 200; G2="$(erv ARGS | sed 's/.*--global-timeout //'):$(erv E2E_TIMEOUT_MS)"
er one --timeout 10; G3="$(erv ARGS | sed 's/.*--global-timeout //'):$(erv E2E_TIMEOUT_MS)"; er three --timeout 30; G4="$(erv ARGS | sed 's/.*--global-timeout //')"
check "e2e-run: global timeout = per-test x top-level flow files x 5, at least 300000 (3 files; ignored .txt, .bak and nested files are not counted); --timeout is seconds" "$G1|$G2|$G3|$G4" "900000|3000000:200000|300000:10000|450000"
TB=""; for t in 0 abc -5 1.5 '' 1e3 ' 5'; do er one --timeout "$t"; TB="$TB$RC:$(erran);"; done; er one --timeout; TB="$TB$RC:$(erran)"
check "e2e-run: --timeout must be a positive whole number (0, text, negative, decimal, empty, exponent, blank, missing) -> exit 1, not run" "$TB" "1:not-run;1:not-run;1:not-run;1:not-run;1:not-run;1:not-run;1:not-run;1:not-run"
TZ=""; for t in 00 000 0000; do er one --timeout "$t"; TZ="$TZ$RC:$(erran):$(printf '%s\n' "$OUT" | grep -c 'positive whole number');"; done
er one --timeout 08; TZ="$TZ$RC:$(erv E2E_TIMEOUT_MS)"; er one --timeout 010; TZ="$TZ:$RC:$(erv E2E_TIMEOUT_MS)"; er one --timeout 09 --list; TZ="$TZ:$RC"
check "e2e-run: --timeout made only of zeros (00, 000, 0000) -> exit 1 with the message, not run; leading zeros are decimal (08 -> 8000 ms, 010 -> 10000 ms, no octal error)" "$TZ" "1:not-run:1;1:not-run:1;1:not-run:1;0:8000:0:10000:0"
rm -rf "$ERW/qa-evidence"; rm -f "$ERA"; printf '%s' "$ERFULL" > "$ERS"
er one --list; L1="$RC:$(erv ARGS):$(erv E2E_STORAGE_STATE):$(erv E2E_FLOW_DIR):$(test -e "$ERW/qa-evidence" && echo evid || echo noevid):$(printf '%s\n' "$OUT" | grep -c '^Evidence:')"
er one --as admin --list; L2="$RC:$(erran):$(erv E2E_STORAGE_STATE):$(test -e "$ERW/qa-evidence" && echo evid || echo noevid):$(printf '%s\n' "$OUT" | grep -c 'no saved session')"
er one --list --timeout 20 -- a=1; L3="$RC:$(erv E2E_TIMEOUT_MS):$(erv E2E_PARAMS):$(erv ARGS | grep -c -- '--global-timeout')"
ER_PW_RC=4 er one --list; L4="$RC"; ER_CHECK_RC=2 er one --list; L5="$RC:$(erran)"; er nope --list; L6="$RC:$(erran)"
er one; L7="$(erv ARGS | grep -c -- '--list')$(erv ARGS | grep -c -- '--reporter')"; rm -f "$ERS"
check "e2e-run --list: playwright test --config <kit config> --list --reporter=list only (no --global-timeout), no storage state even with a saved default session or --as of a missing identity, no evidence dir, no Evidence line, params and timeout still passed, playwright's status returned, stack check and flow checks still apply, a normal run never passes --list" "$L1|$L2|$L3|$L4|$L5|$L6|$L7" "0:test --config $ERK/pw/e2e.config.js --list --reporter=list::$ERW/qa-e2e/one:noevid:0|0:ran::noevid:0|0:20000:{\"a\":\"1\"}:0|4|2:not-run|1:not-run|00"

er one --as admin; A1="$RC:$(erran):$(printf '%s\n' "$OUT" | grep -c "no saved session for identity 'admin'"):$(printf '%s\n' "$OUT" | grep -c '^Login: ~/.orca-roles/bin/browser-login.sh <url> --as admin$')"
printf '{"cookies":[],"origins":[]}' > "$ERA"; er one --as admin; A2="$RC:$(erran)"; printf '{}' > "$ERA"; er one --as admin; A4="$RC:$(erran)"
printf '%s' "$ERFULL" > "$ERA"; er one --as admin; A5="$RC:$(erv E2E_STORAGE_STATE)"; printf '{"cookies":[],"origins":[{"origin":"o"}]}' > "$ERA"; er one --as admin; A6="$RC:$(erv E2E_STORAGE_STATE)"
check "e2e-run --as: missing, empty stub and key-less file -> exit 2 with the login command, not run; a file with cookies or with origins maps to E2E_STORAGE_STATE" "$A1|$A2|$A4|$A5|$A6" "2:not-run:1:1|2:not-run|2:not-run|0:$ERA|0:$ERA"
printf '%s' "$ERFULL" > "$ERA"; printf '%s' "$ERFULL" > "$ERS"; er one --as default; D1="$RC:$(erv E2E_STORAGE_STATE)"; rm -f "$ERS"; er one --as default; D2="$RC:$(erran):$(printf '%s\n' "$OUT" | grep -c '^Login: ~/.orca-roles/bin/browser-login.sh <url>$')"
IB=""; for i in Bad_ID -x a/b ../x Admin '' a.b; do er one --as "$i"; IB="$IB$RC:$(erran):$(printf '%s\n' "$OUT" | grep -c 'invalid identity' || true);"; done; er one --as; IB="$IB$RC:$(erran)"
check "e2e-run --as: default is the default identity's file (login command without --as when missing); invalid identities (also empty) -> exit 1 not run; a bare --as -> 1" "$D1|$D2|$IB" "0:$ERS|2:not-run:1|1:not-run:1;1:not-run:1;1:not-run:1;1:not-run:1;1:not-run:1;1:not-run:1;1:not-run:1;1:not-run"
rm -f "$ERA"; er one; N1="$(erv E2E_STORAGE_STATE)"; printf '%s' "$ERFULL" > "$ERS"; er one; N2="$(erv E2E_STORAGE_STATE)"
printf '{"cookies":[],"origins":[]}' > "$ERS"; er one; N3="$RC:$(erv E2E_STORAGE_STATE)"; rm -f "$ERS"
IJ=""; for j in '{not json' '' '[]' 'null' '"x"' 'junk'; do printf '%s' "$j" > "$ERA"; er one --as admin; IJ="$IJ$RC:$(erran):$(printf '%s\n' "$OUT" | grep -c '^Login: ~/.orca-roles/bin/browser-login.sh <url> --as admin$');"; printf '%s' "$j" > "$ERS"; er one; IJ="$IJ$RC:$(erran):$(erv E2E_STORAGE_STATE);"; er one --as default; IJ="$IJ$RC:$(erran);"; done; rm -f "$ERA" "$ERS"
check "e2e-run: a session file that is invalid JSON, empty, or not an object ([], null, a string) -> with --as (admin or default) exit 2 with the login command, not run; without --as no storage state and the flow still runs" "$IJ" "$(for i in 1 2 3 4 5 6; do printf '2:not-run:1;0:ran:;2:not-run;'; done)"
check "e2e-run: without --as the default identity's session is used only when it exists and is not an empty stub (else no storage state, still runs)" "$N1|$N2|$N3" "|$ERS|0:"

er one -- a=1 'b=x=y' 'c=two words' 'd=' 'e=q"u\o\\te' 'f={"j":1}' _g=ü a=2
P="$(erv E2E_PARAMS)"
check "e2e-run params: -> E2E_PARAMS JSON object of strings (value with =, spaces, empty, quotes, backslashes, JSON text, unicode; a repeated key keeps the last), and never reach playwright's argv" "$RC:$(printf '%s' "$P" | jq -cS .):$(erv ARGS | grep -c 'a=1\|two words')" '0:{"_g":"ü","a":"2","b":"x=y","c":"two words","d":"","e":"q\"u\\o\\\\te","f":"{\"j\":1}"}:0'
check "e2e-run: the default e2eDir is qa-e2e next to evidenceDir; the config matches *.flow.(ts|js), uses channel chromium, one worker, and no device preset" "$(jq -r '.roles["e2e-tester"].params | "\(.e2eDir):\(.evidenceDir)"' "$ROOT/config.default.json"):$(grep -c "testMatch: /\.\*\\\.flow\\\.(ts|js)\$/" "$ROOT/pw/e2e.config.js"):$(grep -c "channel: 'chromium'" "$ROOT/pw/e2e.config.js"):$(grep -c 'workers: 1' "$ROOT/pw/e2e.config.js"):$(grep -c devices "$ROOT/pw/e2e.config.js" || true)" "qa-e2e:qa-evidence:1:1:1:0"
er one -- ; Q1="$RC:$(erv E2E_PARAMS)"; er one -- k=--v; Q2="$RC:$(erv E2E_PARAMS):$(erv E2E_STORAGE_STATE):$(erv ARGS | grep -c 'zz')"
PB=""; for b in novalue =x 1a=x -a=x --as=zz ''; do er one -- ok=1 "$b"; PB="$PB$RC:$(erran);"; done
check "e2e-run params: an empty list gives {}; after -- nothing is an option; a pair not key=value with a key starting with a letter or _ -> exit 1 not run" "$Q1|$Q2|$PB" "0:{}|0:{\"k\":\"--v\"}::0|1:not-run;1:not-run;1:not-run;1:not-run;1:not-run;1:not-run;"
set -e
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
# a failing check ends in FAILURES with exit 1, and a section that ends the script early with exit 0 is not a pass
CF="$TMP/cli-fail"; rm -rf "$CF"; mkdir -p "$CF/tests"; ln -sfn "$ROOT/bin" "$CF/bin"; ln -sfn "$ROOT/prompts" "$CF/prompts"; ln -sfn "$ROOT/config.default.json" "$CF/config.default.json"
sed -e 's/^SECTIONS=.*/SECTIONS="bad quit"/' -e 's/^\[ \$# -gt 0 \] || set -- \$SECTIONS$/sec_bad() { check "marker bad" a b; }; sec_quit() { exit 0; }\
&/' "$ROOT/tests/smoke.sh" > "$CF/tests/smoke.sh"
cli_f() { CRC=0; bash "$CF/tests/smoke.sh" "$@" > "$TMP/cli.out" 2> "$TMP/cli.err" || CRC=$?; }
cli_f bad; check "cli: a failing check prints its FAIL line and FAILURES, exits 1, no ALL OK" "$CRC:$(grep -c '^FAIL marker bad: expected \[b\], got \[a\]$' "$TMP/cli.out"):$(grep -c '^FAILURES$' "$TMP/cli.out"):$(grep -c '^ALL OK' "$TMP/cli.out")" "1:1:1:0"
cli_f quit; check "cli: a section that exits 0 early -> exit 1, 'ended before its summary' on stderr, no ALL OK" "$CRC:$(grep -c '^smoke.sh: ended before its summary$' "$TMP/cli.err"):$(grep -c '^ALL OK' "$TMP/cli.out")" "1:1:0"
# the rules helpers fail loudly: an unmodified copy of the prompts passes, a lost fragment or a renamed pr-reviewer section does not
RT="$TMP/rules-selftest"; rm -rf "$RT"; mkdir -p "$RT/tests"; cp -R "$ROOT/bin" "$ROOT/prompts" "$ROOT/config.default.json" "$ROOT/README.md" "$RT/"; mkdir -p "$RT/plugin"; cp -R "$ROOT/plugin/skills" "$RT/plugin/"; cp "$ROOT/tests/smoke.sh" "$RT/tests/smoke.sh"
rt_run() { CRC=0; bash "$RT/tests/smoke.sh" rules > "$TMP/cli.out" 2> "$TMP/cli.err" || CRC=$?; }
rt_run; check "rules helpers: an unmodified copy of the prompts passes" "$CRC:$(grep -c '^FAIL' "$TMP/cli.out"):$(grep -c '^ALL OK' "$TMP/cli.out")" "0:0:1"
sed -i.bak "s/Nothing leaves the worktree without the user's explicit yes/Nothing leaves/" "$RT/prompts/programmer/planner.md"; rm -f "$RT/prompts/programmer/planner.md.bak"
rt_run; check "rules helpers: a pinned fragment removed from a prompt -> 'FAIL rules R1' naming the file, FAILURES, exit 1, no ALL OK" "$CRC:$(grep -c "^FAIL rules R1: prompts/programmer/planner.md lost 'Nothing leaves the worktree without the user's explicit yes'$" "$TMP/cli.out"):$(grep -c '^FAILURES$' "$TMP/cli.out"):$(grep -c '^ALL OK' "$TMP/cli.out")" "1:1:1:0"
rm -rf "$RT/prompts"; cp -R "$ROOT/prompts" "$RT/"; sed -i.bak 's/^## The review skill$/## Review skill/' "$RT/prompts/pr-reviewer/planner.md"; rm -f "$RT/prompts/pr-reviewer/planner.md.bak"
rt_run; check "rules helpers: a pr-reviewer section whose title is gone makes its pins fail (prsec finds nothing)" "$CRC:$(grep -c "^FAIL rules R6: pr-reviewer planner.md, section 'The review skill', lost " "$TMP/cli.out"):$(grep -c '^ALL OK' "$TMP/cli.out")" "1:2:0"
}

[ $# -gt 0 ] || set -- $SECTIONS
for s in "$@"; do "sec_${s//-/_}"; done
sleep 1

DONE=1
[ "$FAIL" = 0 ] && echo "ALL OK" || { echo "FAILURES"; exit 1; }
