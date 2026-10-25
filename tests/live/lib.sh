#!/usr/bin/env bash
# Shared helpers of the live checks (tests/live/*.sh): what the smoke tests cannot cover because it needs a real Orca,
# real agents, the network or a person. See docs/live-checks.md. Sourced, never run.
# Everything runs in a throwaway project ($LIVE_DIR/project, registered in Orca once and reused); the user's own teams are
# never touched. Each script writes one report ($LIVE_DIR/report-<script>.md) to hand back to the Planner.

LIVE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # this checkout of the kit
KIT="$HOME/.orca-roles"
LIVE_DIR="${ORCA_LIVE_DIR:-$HOME/orca-live-checks}"
PROJ="$LIVE_DIR/project"
MODEL="${ORCA_LIVE_MODEL:-claude-haiku-5-5}"   # every agent of the throwaway team: the cheapest model
mkdir -p "$LIVE_DIR"

# ---------- report ----------
live_start() {  # live_start <script name>: opens (or continues) the report and the state file
  NAME="$1"; REPORT="$LIVE_DIR/report-$NAME.md"; STATE="$LIVE_DIR/state-$NAME"
  if [ ! -f "$STATE" ]; then
    {
      echo "# Live checks: $NAME"
      echo
      echo "- Date: $(date '+%F %T %z')"
      echo "- Kit checkout: $(git -C "$LIVE_ROOT" rev-parse --short HEAD 2>/dev/null) ($(git -C "$LIVE_ROOT" branch --show-current 2>/dev/null)), $(git -C "$LIVE_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ') uncommitted files"
      echo "- Orca: $(orca --version 2>/dev/null | head -1)   Claude Code: $(claude --version 2>/dev/null | head -1)"
      echo "- System: $(uname -sr)$(live_is_wsl && echo ' (WSL)')"
      echo
      echo "| Check | Result | Detail |"
      echo "|---|---|---|"
    } > "$REPORT"
    : > "$STATE"
  fi
}
row() {  # row <id> <OK|FAIL|INFO|SKIP> <detail>
  local d; d="$(printf '%s' "$3" | tr '\n|' ' /' | cut -c1-600)"
  printf '| %s | %s | %s |\n' "$1" "$2" "$d" >> "$REPORT"
  printf '%-6s %-5s %s\n' "$1" "$2" "$d"
}
ok()   { row "$1" OK "$2"; }
fail() { row "$1" FAIL "$2"; }
info() { row "$1" INFO "$2"; }
skip() { row "$1" SKIP "$2"; }
check() {  # check <id> <description> <actual> <expected>
  if [ "$3" = "$4" ]; then ok "$1" "$2"; else fail "$1" "$2: got [$3], expected [$4]"; fi
}
attach() {  # attach <title> <file or text>: appends a log excerpt to the report
  { echo; echo "<details><summary>$1</summary>"; echo; echo '```'
    if [ -f "$2" ]; then tail -n 60 "$2"; else printf '%s\n' "$2" | tail -n 60; fi
    echo '```'; echo "</details>"; } >> "$REPORT"
}
st_get() { grep "^$1=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2-; }
st_set() { local t="$STATE.tmp"; grep -v "^$1=" "$STATE" > "$t" 2>/dev/null; printf '%s=%s\n' "$1" "$2" >> "$t"; mv "$t" "$STATE"; }
done_check() { [ "$(st_get "done.$1")" = 1 ]; }   # a check already run in an earlier run of the script is not run again
mark_done() { st_set "done.$1" 1; }
ask() {  # ask <text>: a step only the user can do; waits for Enter
  printf '\n>>> %s\n>>> Press Enter when done (or type "skip" to skip this check): ' "$1"
  local a; read -r a < /dev/tty; [ "$a" != skip ]
}

# ---------- environment ----------
live_is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is missing." >&2; exit 1; }; }
live_preflight() {  # the installed kit must be this checkout (the checks test the code, not an older install)
  need jq; need git; need orca
  [ -n "${ORCA_WORKTREE_ID:-}" ] || { echo "ERROR: run this from an Orca terminal (ORCA_WORKTREE_ID is not set)." >&2; exit 1; }
  local d; d="$(diff -rq "$LIVE_ROOT/bin" "$KIT/bin" 2>/dev/null | grep -v 'Only in /' | head -3)"
  [ -n "$d" ] && { echo "ERROR: the installed kit (~/.orca-roles/bin) differs from this checkout. Install it first: $LIVE_ROOT/install.sh" >&2; echo "$d" >&2; exit 1; }
  return 0
}
handle_of() { jq -r '[.. | .handle? // empty] | first // empty' 2>/dev/null; }   # the handle in a JSON answer of orca
jfield() { python3 -c 'import sys,json
try: d=json.loads(sys.stdin.read(),strict=False)
except Exception: sys.exit(0)
for k in sys.argv[1].split("."):
    d=d.get(k) if isinstance(d,dict) else None
    if d is None: sys.exit(0)
print(d if not isinstance(d,(dict,list)) else json.dumps(d))' "$1"; }

# ---------- throwaway project and worktree ----------
project_setup() {  # creates $PROJ once: a git repo with a cheap team (.orca-roles.json), the kit as setup script, registered in Orca
  if [ ! -d "$PROJ/.git" ]; then
    mkdir -p "$PROJ" && git -C "$PROJ" init -q -b main
    echo "# orca-roles live checks (throwaway)" > "$PROJ/README.md"
    jq -n --arg m "$MODEL" '{settings: {jiraHandoff: false, cleanWorkersAfterStep: false, language: "auto"},
      roles: {planner: {model: $m}, dev: {model: $m}, tester: {model: $m}, auditor: {model: $m},
              researcher: {enabled: false}, "e2e-tester": {enabled: false}, deployer: {enabled: false}}}' > "$PROJ/.orca-roles.json"
    git -C "$PROJ" add -A && git -C "$PROJ" -c user.name=live -c user.email=live@localhost commit -qm "live checks project"
  fi
  (cd "$PROJ" && "$KIT/bin/orca-yaml.sh" >/dev/null 2>&1) || true    # setup script without --mode: a new worktree asks the mode
  orca repo add --path "$PROJ" --json >/dev/null 2>&1 || true
}
WT=""; WTID=""; GD=""
wt_load() { WT="$(st_get wt)"; WTID="$(st_get wtid)"; [ -n "$WT" ] && GD="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)"; }
wt_create() {  # wt_create <name> [orca worktree create options...]: a new worktree of $PROJ; sets WT, WTID, GD
  local name="$1" out; shift
  out="$(orca worktree create --repo "path:$PROJ" --name "$name" --setup run --json "$@" 2>&1)"
  WT="$(printf '%s' "$out" | jfield result.worktree.path)"; WTID="$(printf '%s' "$out" | jfield result.worktree.id)"
  [ -n "$WT" ] || { printf '%s\n' "$out" | head -5 >&2; return 1; }
  GD="$(git -C "$WT" rev-parse --absolute-git-dir)"; st_set wt "$WT"; st_set wtid "$WTID"
}
wt_terms() {  # one line per live terminal of the worktree: handle<TAB>ptyId<TAB>title<TAB>agent
  orca terminal list --worktree "id:$WTID" --json 2>/dev/null | python3 -c 'import sys,json
d=json.loads(sys.stdin.read(),strict=False)
for t in (d.get("result") or {}).get("terminals") or []:
    print("\t".join([t.get("handle",""), t.get("ptyId",""), t.get("title") or "", t.get("agentIdentity") or ""]))'
}
roles_run() {  # roles_run [options]: the kit's launch in the worktree, from this terminal (the kit takes the folder's worktree); output in $LIVE_DIR/last-roles.log
  (cd "$WT" && "$KIT/bin/launch.sh" "$@") > "$LIVE_DIR/last-roles.log" 2>&1; local rc=$?
  kickoff_wait; return $rc
}
kickoff_wait() {  # waits (up to 300 s) until no kickoff of the worktree is running
  local _; for _ in $(seq 1 150); do [ -z "$(ls -A "$GD/orca-roles.kickoff.d" 2>/dev/null)" ] && return 0; sleep 2; done; return 1
}
env_of() { grep "^$1=" "$GD/orca-roles.env" 2>/dev/null | cut -d= -f2-; }
screen() {  # screen <handle> [lines]: the last lines of a terminal's screen
  orca terminal read --terminal "$1" --json 2>/dev/null | python3 -c 'import sys,json
d=json.loads(sys.stdin.read(),strict=False); t=(d.get("result") or {}).get("terminal") or {}
L=[l for l in t.get("tail",[]) if isinstance(l,str) and l.strip()]
print("\n".join(L[-int(sys.argv[1]):]))' "${2:-40}"
}
wait_screen() {  # wait_screen <handle> <extended regex> <seconds>: 0 when the screen matches in time
  local _; for _ in $(seq 1 "$3"); do screen "$1" 80 | grep -Eqi "$2" && return 0; sleep 1; done; return 1
}
pid_of_handle() {  # the agent process (claude or codex) whose environment has ORCA_TERMINAL_HANDLE=<handle>
  local pid env
  for pid in $(ps -axo pid=,comm= 2>/dev/null | awk '$2 ~ /(^|\/)(claude|codex|opencode)$/ {print $1}'); do
    if [ -r "/proc/$pid/environ" ]; then env="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)"; else env="$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n')"; fi
    printf '%s\n' "$env" | grep -qx "ORCA_TERMINAL_HANDLE=$1" && { echo "$pid"; return 0; }
  done
  return 1
}
env_of_pid() { if [ -r "/proc/$1/environ" ]; then tr '\0' '\n' < "/proc/$1/environ"; else ps eww -p "$1" | tr ' ' '\n'; fi; }
wt_cleanup() {  # closes every tab of the throwaway worktree and removes it
  [ -n "$WTID" ] || return 0
  orca terminal close --worktree "id:$WTID" --all --json >/dev/null 2>&1
  orca worktree rm --worktree "id:$WTID" --force --json >/dev/null 2>&1 || true
}

# ---------- checks shared by mac.sh and wsl.sh ----------
c_smoke_combo() {  # sections that failed together once (#29) must pass together
  local id=$1 out rc
  out="$("$LIVE_ROOT/tests/smoke.sh" launch restart reopen wake worktree-select 2>&1)"; rc=$?
  if [ $rc = 0 ] && printf '%s' "$out" | grep -q 'ALL OK'; then ok "$id" "smoke launch+restart+reopen+wake+worktree-select together: ALL OK"
  else fail "$id" "smoke sections together: rc=$rc"; attach "$id smoke" "$(printf '%s\n' "$out" | grep -E 'FAIL|aborted' | head -40)"; fi
}
c_upgrade_no_roles() {  # upgrade_config on a user config without "roles" (#37: "null has no keys")
  local id=$1 t out rc
  t="$(mktemp -d)"; echo '{"settings":{"language":"auto"}}' > "$t/config.json"
  out="$(bash -c '. "$1/bin/lib.sh"; upgrade_config "$1/config.default.json" "$2/config.json" "$1"' _ "$LIVE_ROOT" "$t" 2>&1)"; rc=$?
  if [ $rc = 0 ] && printf '%s' "$out" | jq -e '.roles.planner' >/dev/null 2>&1; then ok "$id" "upgrade_config on a config with no roles key works"
  else fail "$id" "upgrade_config on a config with no roles key: rc=$rc $(printf '%s' "$out" | head -2) (known since #37)"; fi
  rm -rf "$t"
}
c_scholar() {  # scholar.sh against the live APIs (#28)
  local id=$1 s="$KIT/bin/scholar.sh" t out
  t="$(mktemp -d)"; git -C "$t" init -q
  out="$("$s" search "attention is all you need" --source openalex --limit 2 2>&1)"
  printf '%s' "$out" | grep -qi attention && ok "$id.openalex" "search on OpenAlex" || fail "$id.openalex" "$(printf '%s' "$out" | tail -2)"
  out="$("$s" search "transformer" --source arxiv --limit 2 2>&1)"
  printf '%s' "$out" | grep -q '^arxiv' && ok "$id.arxiv" "search on arXiv" || fail "$id.arxiv" "$(printf '%s' "$out" | tail -2)"
  out="$("$s" search "attention is all you need" --source arxiv --limit 2 2>&1)"
  printf '%s' "$out" | grep -q '^arxiv' && ok "$id.arxiv-phrase" "a several-word search on arXiv finds results" || fail "$id.arxiv-phrase" "a several-word search on arXiv returns nothing (one word works)"
  out="$("$s" search "attention is all you need" --source s2 --limit 2 2>&1)"
  if printf '%s' "$out" | grep -qi attention; then ok "$id.s2" "search on Semantic Scholar$([ -n "${S2_API_KEY:-}" ] && echo ' (with key)' || echo ' (no key)')"
  else info "$id.s2" "Semantic Scholar: $(printf '%s' "$out" | tail -1) (set S2_API_KEY to test with a key)"; fi
  out="$("$s" show 10.1038/nature14539 2>&1)"; printf '%s' "$out" | grep -q '^title:' && ok "$id.show" "show a Crossref DOI" || fail "$id.show" "$(printf '%s' "$out" | tail -2)"
  out="$("$s" bibtex 10.48550/arXiv.1706.03762 2>&1)"; printf '%s' "$out" | grep -q '^@' && ok "$id.datacite" "bibtex of a DataCite DOI through doi.org" || fail "$id.datacite" "$(printf '%s' "$out" | tail -1)"
  out="$("$s" bibtex 10.1093/nar/gkab1112 2>&1)"; printf '%s' "$out" | grep -q '^@' && ok "$id.bibtex" "bibtex of a Crossref DOI" || fail "$id.bibtex" "$(printf '%s' "$out" | tail -2)"
  mkdir -p "$t/article"; (cd "$t" && "$s" bibtex arxiv:1706.03762 --add >/dev/null 2>&1)
  out="$(cd "$t" && "$s" verify 2>&1)"; printf '%s' "$out" | grep -qE '	ok' && ok "$id.verify" "verify a .bib against arXiv" || fail "$id.verify" "$(printf '%s' "$out" | tail -2)"
  out="$(cd "$t" && SCHOLAR_EMAIL="${SCHOLAR_EMAIL:-live-checks@example.com}" "$s" pdf arxiv:1706.03762 2>&1)"
  printf '%s' "$out" | grep -qE '^(downloaded|present)' && ok "$id.pdf" "pdf of an arXiv paper (real download, size limit)" || fail "$id.pdf" "$(printf '%s' "$out" | tail -2)"
  rm -rf "$t"
}
c_roles_yaml_all() {  # roles-yaml --all against the projects registered in Orca, without writing (#32)
  local id=$1 out rc
  out="$("$KIT/bin/orca-yaml.sh" --all --dry-run 2>&1)"; rc=$?
  [ $rc = 0 ] && ok "$id" "roles-yaml --all --dry-run over $(printf '%s\n' "$out" | grep -c . ) lines, nothing written" || fail "$id" "rc=$rc"
  attach "$id roles-yaml --all --dry-run" "$out"
}
c_install_superpowers() {  # a fresh install into a temporary HOME: the real superpowers fetch, a session with it, a real plugin install (#39)
  local id=$1 t out
  t="$LIVE_DIR/home"; rm -rf "$t"; mkdir -p "$t"
  out="$(HOME="$t" "$LIVE_ROOT/install.sh" 2>&1)"
  if [ -f "$t/.orca-roles/plugins/superpowers/.claude-plugin/plugin.json" ] || [ -d "$t/.orca-roles/plugins/superpowers/skills" ]; then
    ok "$id.fetch" "install fetched the pinned superpowers from GitHub"
  else fail "$id.fetch" "no superpowers after install"; attach "$id install" "$out"; fi
  if command -v claude >/dev/null; then
    out="$(claude -p --model "$MODEL" --plugin-dir "$t/.orca-roles/plugins/superpowers" "List the names of the skills you have whose name starts with 'superpowers:'. Reply with the names only." 2>&1 | head -40)"
    printf '%s' "$out" | grep -qi 'brainstorming\|writing-plans' && ok "$id.session" "a Claude session loads the pinned superpowers skills" || fail "$id.session" "$(printf '%s' "$out" | tail -3)"
    mkdir -p "$t/proj/.claude" && git -C "$t/proj" init -q
    printf '%s\n' '{"extraKnownMarketplaces":{"superpowers-dev":{"source":{"source":"github","repo":"obra/superpowers"}}},"enabledPlugins":{"superpowers@superpowers-dev":true}}' > "$t/proj/.claude/settings.json"
    out="$(CLAUDE_CONFIG_DIR="$t/claude" HOME="$t" "$t/.orca-roles/bin/project-plugins.sh" install superpowers@superpowers-dev "$t/proj" 2>&1)"
    printf '%s' "$out" | grep -q '^installed' && ok "$id.plugin" "project-plugins.sh install: real marketplace add + install (temporary Claude config)" || fail "$id.plugin" "$(printf '%s' "$out" | tail -2)"
    out="$(CLAUDE_CONFIG_DIR="$t/claude" HOME="$t" "$t/.orca-roles/bin/project-plugins.sh" status "$t/proj" 2>&1)"
    printf '%s' "$out" | grep -q 'installed' && ok "$id.status" "status after the install: installed" || fail "$id.status" "$out"
  else skip "$id.session" "claude is not installed"; fi
}
c_new_role_wizard() {  # the new-role wizard typed by a person (#28), in the temporary HOME of c_install_superpowers
  local id=$1 t="$LIVE_DIR/home"
  [ -x "$t/.orca-roles/bin/new-role.sh" ] || { skip "$id" "needs the temporary install of the superpowers check"; return; }
  echo; echo ">>> The new-role wizard opens in a TEMPORARY kit ($t/.orca-roles); your kit is not touched."
  echo ">>> Create a role with id 'live-probe', any title and description, mode programmer, agent claude; defaults for the rest."
  HOME="$t" "$t/.orca-roles/bin/new-role.sh" < /dev/tty
  if jq -e '.roles["live-probe"]' "$t/.orca-roles/config.json" >/dev/null 2>&1 && [ -s "$t/.orca-roles/roles/programmer/live-probe.md" ]; then
    ok "$id" "the wizard created live-probe (config and prompt)"
  else fail "$id" "no live-probe role in the temporary kit's config.json or roles/programmer/"; fi
}
c_e2e() {  # the pinned E2E stack: install, a real login (cookie + localStorage), a flow against a real local app (#31)
  local id=$1 port=8765 app="$LIVE_DIR/app" out rc srv
  "$KIT/bin/e2e-browser.sh" check >/dev/null 2>&1 || { out="$("$KIT/bin/e2e-browser.sh" install 2>&1)" || { fail "$id.install" "$(printf '%s' "$out" | tail -2)"; return; }; }
  ok "$id.install" "the pinned Playwright stack is installed (e2e-browser.sh check)"
  mkdir -p "$app"
  printf '%s\n' '<!doctype html><title>live</title><h1>live-checks</h1><script>document.cookie="live=1; path=/; max-age=86400"; localStorage.setItem("live","1")</script>' > "$app/index.html"
  (cd "$app" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & srv=$!
  sleep 1
  echo; echo ">>> A browser opens at http://127.0.0.1:$port/ . When the page shows 'live-checks', CLOSE the browser window."
  out="$(cd "$PROJ" && "$KIT/bin/browser-login.sh" "http://127.0.0.1:$port/" 2>&1)"; rc=$?
  [ $rc = 0 ] && ok "$id.login" "browser-login.sh saved a session ($(printf '%s' "$out" | grep -o 'Session saved:.*'))" || fail "$id.login" "$(printf '%s' "$out" | tail -2)"
  out="$(cd "$PROJ" && "$KIT/bin/e2e-browser.sh" session "http://127.0.0.1:$port/" 2>&1)"; rc=$?
  check "$id.session" "e2e-browser.sh session reads the saved session" "$rc" 0
  mkdir -p "$PROJ/qa-e2e/live"
  printf '%s\n' "const { test, expect } = require('@playwright/test');" \
    "test('the page loads with the saved session', async ({ page, context }) => {" \
    "  const p = JSON.parse(process.env.E2E_PARAMS || '{}');" \
    "  await page.goto(p.url);" \
    "  await expect(page.locator('h1')).toHaveText('live-checks');" \
    "  const c = await context.cookies(); expect(c.some(x => x.name === 'live')).toBeTruthy();" \
    "});" > "$PROJ/qa-e2e/live/page.flow.js"
  out="$(cd "$PROJ" && "$KIT/bin/e2e-run.sh" live --as default -- "url=http://127.0.0.1:$port/" 2>&1)"; rc=$?
  [ $rc = 0 ] && ok "$id.flow" "e2e-run.sh ran a flow with the saved session against a real app" || { fail "$id.flow" "rc=$rc"; attach "$id e2e-run" "$out"; }
  kill "$srv" 2>/dev/null
}
c_fresh_worktree() {  # a new worktree created by Orca with an agent: the setup script runs the kit, only the Planner opens and asks the mode; the composer's extra session (#1, #45)
  local id=$1 terms
  wt_create "live-$(date +%H%M%S)" --agent claude --model "$MODEL" --prompt "Reply only: ok" || { fail "$id" "orca worktree create failed"; return 1; }
  for _ in $(seq 1 90); do [ -s "$GD/orca-roles-kickoff.log" ] && [ -z "$(ls -A "$GD/orca-roles.kickoff.d" 2>/dev/null)" ] && break; sleep 2; done
  check "$id.marker" "the mode is pending after a fresh start (orca-roles.mode-pending)" "$([ -e "$GD/orca-roles.mode-pending" ] && echo yes)" yes
  check "$id.only-planner" "only the Planner was opened" "$(cut -d= -f1 "$GD/orca-roles.env" 2>/dev/null | tr '\n' ' ')" "PLANNER "
  wait_screen "$(env_of PLANNER)" 'pr-reviewer' 120 && ok "$id.asks" "the Planner asks which mode (its screen names the modes)" || fail "$id.asks" "the Planner's screen does not name the modes after 120 s"
  terms="$(wt_terms)"
  info "$id.composer" "kickoff: $(grep -iE 'composer|Closed' "$GD/orca-roles-kickoff.log" | tr '\n' ' ' | cut -c1-300); seen titles: $(jq -c '[.[]?.title]' "$GD/orca-roles.composer-seen.json" 2>/dev/null)"
  check "$id.composer-closed" "no tab other than the Planner's runs an agent" "$(printf '%s\n' "$terms" | awk -F'\t' '$4 != ""' | grep -vc "$(env_of PLANNER)" | tr -d ' ')" 0
  attach "$id terminals after the fresh start" "$terms"
}
c_choose_mode() {  # the mode chosen from another worktree's terminal: the kit takes the folder's worktree (n13 B5) and opens the team (#45)
  local id=$1
  roles_run --mode programmer
  grep -q 'using the worktree of the current folder' "$LIVE_DIR/last-roles.log" && ok "$id.folder" "launch.sh took the folder's worktree, not this terminal's" || fail "$id.folder" "no 'using the worktree of the current folder' line"
  check "$id.team" "the programmer team is open" "$(cut -d= -f1 "$GD/orca-roles.env" | sort | tr '\n' ' ')" "AUDITOR DEV PLANNER TESTER "
  check "$id.marker" "the mode is no longer pending" "$([ -e "$GD/orca-roles.mode-pending" ] && echo yes || echo no)" no
  attach "$id roles --mode programmer" "$LIVE_DIR/last-roles.log"
}
c_pty_file() {  # orca-roles.pty holds exactly the ptyId Orca reports for each role (WSL ptyIds have backslashes: n13 awk fix)
  local id=$1 bad="" v h p
  while IFS='=' read -r v h; do
    p="$(orca terminal show --terminal "$h" --json 2>/dev/null | jfield result.terminal.ptyId)"
    [ "$(grep "^$v=" "$GD/orca-roles.pty" | cut -d= -f2-)" = "$p" ] || bad="$bad $v"
  done < "$GD/orca-roles.env"
  check "$id" "orca-roles.pty matches Orca's ptyId byte for byte for every role" "${bad:-none}" none
}
c_tester_nice() {  # the Tester runs at nice 10 with the thread caps (#8)
  local id=$1 pid
  pid="$(pid_of_handle "$(env_of TESTER)")" || { fail "$id" "no Tester process found"; return; }
  check "$id.nice" "the Tester's agent runs at nice 10" "$(ps -o ni= -p "$pid" | tr -d ' ')" 10
  check "$id.threads" "the Tester's environment caps threads (OMP_NUM_THREADS=2)" "$(env_of_pid "$pid" | grep -x 'OMP_NUM_THREADS=2')" OMP_NUM_THREADS=2
}
c_handles_changed() {  # a worker reopened while the Planner keeps its tab: kickoff's background shell tells the Planner (#29)
  local id=$1 dev
  dev="$(env_of DEV)"; orca terminal close --terminal "$dev" --tab --json >/dev/null 2>&1; sleep 2
  roles_run
  grep -q 'Role handles changed' "$GD/orca-roles-kickoff.log" && ok "$id" "kickoff sent the Planner 'Role handles changed'" || fail "$id" "no 'Role handles changed' in the kickoff log"
  attach "$id kickoff log" "$GD/orca-roles-kickoff.log"
}
c_switch_from_planner() {  # a mode switch typed in the Planner's own tab: workers closed quickly, Esc + clear while kickoff runs, role message (#45)
  local id=$1 to=$2 expect=$3 pl t0 t1
  pl="$(env_of PLANNER)"; t0=$SECONDS
  orca terminal send --terminal "$pl" --text "!$KIT/bin/launch.sh --mode $to" --enter --json >/dev/null 2>&1
  sleep 5; kickoff_wait; t1=$SECONDS
  check "$id.team" "after switching to $to the team is" "$(cut -d= -f1 "$GD/orca-roles.env" | sort | tr '\n' ' ')" "$expect"
  check "$id.file" "the switch-from file is gone" "$([ -e "$GD/orca-roles.switch-from" ] && echo present || echo gone)" gone
  grep -q 'cleared' "$GD/orca-roles-kickoff.log" && ok "$id.clear" "the Planner's conversation was cleared ($(grep -o 'cleared ([^)]*)' "$GD/orca-roles-kickoff.log" | head -1))" || fail "$id.clear" "no clear in the kickoff log"
  wait_screen "$pl" "switched from" 90 && ok "$id.msg" "the Planner got the new mode's role message" || fail "$id.msg" "no 'switched from' on the Planner's screen"
  check "$id.tabs" "role tabs open in the worktree (one per role, no leftovers)" "$(wt_terms | awk -F'\t' '$3 ~ /\(claude\)$/ || $4 != ""' | wc -l | tr -d ' ')" "$(grep -c . "$GD/orca-roles.env")"
  info "$id.time" "switch took $((t1 - t0)) s"
}
c_restart_prepare() {  # before the restart: what each role had
  cp "$GD/orca-roles.env" "$LIVE_DIR/env-before-restart"; wt_terms > "$LIVE_DIR/terms-before-restart"
}
c_restart_after() {  # after a real restart: asleep tabs are woken and reopened with their conversation, no duplicate (n13, #8, #38)
  local id=$1 asleep live t0 t1 r
  live="$(wt_terms)"; asleep=""
  while IFS='=' read -r v h; do printf '%s\n' "$live" | grep -q "$(grep "^$v=" "$GD/orca-roles.pty" | cut -d= -f2-)" || asleep="$asleep $v"; done < "$GD/orca-roles.env"
  info "$id.asleep" "roles asleep after the restart (not in terminal list):${asleep:- none}"
  attach "$id terminals after the restart, before roles" "$live"
  t0=$SECONDS; roles_run; t1=$SECONDS
  attach "$id roles after the restart" "$LIVE_DIR/last-roles.log"
  info "$id.time" "roles took $((t1 - t0)) s"
  r="$(grep -c 'woke it' "$LIVE_DIR/last-roles.log")"
  if live_is_wsl; then
    grep -q 'Cannot wake tabs' "$LIVE_DIR/last-roles.log" && info "$id.wake" "WSL: the kit says it cannot wake asleep tabs (expected until the WSL PR)" || info "$id.wake" "woke $r tabs"
  else
    check "$id.wake" "every asleep role was woken" "$r" "$(echo $asleep | wc -w | tr -d ' ')"
  fi
  check "$id.memory" "every role reopened with its conversation" "$(grep -c 'reopening it with its conversation' "$LIVE_DIR/last-roles.log")" "$(grep -c . "$GD/orca-roles.env")"
  check "$id.lost" "no role started without memory" "$(grep -c 'no longer exists\|could not be read\|treated as closed' "$LIVE_DIR/last-roles.log")" 0
  sleep 20
  check "$id.duplicates" "one tab per role and no stray agent tab" "$(wt_terms | awk -F'\t' '$4 != ""' | wc -l | tr -d ' ')" "$(grep -c . "$GD/orca-roles.env")"
  local bad=""; while IFS='=' read -r v h; do orca terminal show --terminal "$h" --json >/dev/null 2>&1 || bad="$bad $v"; done < "$GD/orca-roles.env"
  check "$id.handles" "every handle in orca-roles.env is live (WSL stale handles, BACKLOG)" "${bad:-none}" none
}
restart_instructions() {
  if live_is_wsl; then
    echo ">>> Now a REAL restart: close Orca, then end every Orca process (Task Manager, or reboot Windows)."
  else
    echo ">>> Now a REAL restart: quit Orca (Cmd+Q), then in macOS's Terminal app (not Orca) run:  pkill -f 'out/main/daem'"
  fi
  echo ">>> Your own teams are affected too: afterwards run roles in each of them (this kit wakes them)."
  echo ">>> Open Orca, open ONE terminal of this repo's main checkout (do not click the live-checks worktree's tabs) and run the same command again:"
  echo ">>>   $LIVE_ROOT/tests/live/$NAME.sh"
}
run_check() {  # run_check <id> <function> [args...]: runs a check once; a later run of the script skips it
  done_check "$1" && { echo "($1 already done in an earlier run)"; return 0; }
  "$2" "$1" "${@:3}"; mark_done "$1"
}
# The common sequence of mac.sh and wsl.sh: everything before the restart, then (on the next run) everything after it.
live_main() {
  live_start "$1"; live_preflight
  local phase; phase="$(st_get phase)"; wt_load
  if [ -z "$phase" ]; then
    echo "== Part 1: checks without Orca"
    run_check X1 c_smoke_combo
    run_check X2 c_upgrade_no_roles
    run_check X3 c_scholar
    run_check X4 c_roles_yaml_all
    run_check X5 c_install_superpowers
    run_check X6 c_new_role_wizard
    run_check X7 c_e2e
    "${EXTRA_BEFORE:-:}"
    echo "== Part 2: a throwaway team in Orca"
    project_setup
    run_check T1 c_fresh_worktree
    wt_load
    [ -n "$WT" ] && [ -n "$GD" ] || { echo "ERROR: no throwaway worktree (check T1 in the report)." >&2; return 1; }
    run_check T2 c_choose_mode
    run_check T3 c_pty_file
    run_check T4 c_tester_nice
    run_check T5 c_handles_changed
    run_check T6 c_switch_from_planner pr-reviewer "AUDITOR PLANNER "
    run_check T7 c_switch_from_planner programmer "AUDITOR DEV PLANNER TESTER "
    "${EXTRA_TEAM:-:}"
    c_restart_prepare; st_set phase restarted
    echo; restart_instructions
    echo "Report so far: $REPORT"
    return 0
  fi
  if [ "$phase" = restarted ]; then
    echo "== Part 3: after the restart"
    run_check R1 c_restart_after
    run_check R2 c_pty_file
    "${EXTRA_AFTER:-:}"
    wt_cleanup; st_set phase finished
    echo; echo "Finished. Send the report to the Planner: $REPORT"
    echo "To run everything again from the start: rm $STATE"
    return 0
  fi
  echo "Already finished. Report: $REPORT (to run again: rm $STATE)"
}
