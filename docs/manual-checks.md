# Manual checks

The same checks as the live scripts (`docs/live-checks.md`), as a guide to follow by hand: what to do, what to look at, what to write down. Use it when you want to see each step yourself, or when a script's check fails and you want to repeat it. The ids are the scripts' ids.

Before you start:

- Install the checkout you want to check: `cd <checkout> && ./install.sh`.
- Use a throwaway project, never one of your teams: `~/orca-live-checks/project` if a script already created it; otherwise create a git repo with one commit, add it to Orca (`orca repo add --path <folder>`) and run `roles-yaml` in it (no `--mode`, so new worktrees ask the mode).
- Give it a cheap team: an `.orca-roles.json` with `claude-haiku-5-5` for planner, dev, tester, plan-reviewer and code-reviewer, and researcher, e2e-tester and deployer disabled (the scripts' project has one).
- Keep a copy of the results table at the end and fill it as you go.

On WSL do the same steps; where a step differs, it says so. The kit's shim is `~/.orca-roles/shim/orca`: if `orca` is not found in a WSL terminal, put `~/.orca-roles/shim` first in your PATH (the scripts do it themselves).

## 1. Without Orca (about 10 minutes)

| Id | Do | Look at | Expected |
|---|---|---|---|
| X1 | `tests/smoke.sh launch restart reopen wake worktree-select` | the last line | `ALL OK` |
| X2 | `bash -c '. bin/lib.sh; upgrade_config config.default.json <(echo "{}") .'` | the output | The upgraded config, with every role of `config.default.json` in its order (no error) |
| X3 | `~/.orca-roles/bin/scholar.sh search "transformer" --source arxiv --limit 2`, the same with `"attention is all you need"`, then `--source openalex` and `--source s2`; `scholar.sh show 10.1038/nature14539`; `scholar.sh bibtex 10.48550/arXiv.1706.03762` | results per source | Rows for each source, also for the several-word arXiv search; Semantic Scholar may fail without `S2_API_KEY` |
| X3 | In a scratch git repo: `scholar.sh bibtex arxiv:1706.03762 --add`, `scholar.sh verify`, `scholar.sh pdf arxiv:1706.03762` | the three outputs | The key added, the entry `ok`, `downloaded <key> <file>` |
| X4 | `roles-yaml --all --dry-run` | the list | One line per project in Orca; nothing written (`git status` in a few of them is unchanged); not every project is skipped |
| X5 | `HOME=/tmp/live-home ./install.sh` | the end of the output and `/tmp/live-home/.orca-roles/plugins/superpowers` | Superpowers fetched from GitHub |
| X5 | `claude -p --model claude-haiku-5-5 --plugin-dir /tmp/live-home/.orca-roles/plugins/superpowers "List your superpowers skills"` | the answer | Names like brainstorming, writing-plans |
| X5 | A folder with `.claude/settings.json` declaring a plugin (see `tests/live/lib.sh`, `c_install_superpowers`), then `CLAUDE_CONFIG_DIR=/tmp/live-home/claude HOME=/tmp/live-home ~/.orca-roles/bin/project-plugins.sh install <id> <folder>` and `status` | the outputs | `installed <id>`, then `installed` in status |
| X6 | `HOME=/tmp/live-home /tmp/live-home/.orca-roles/bin/new-role.sh`: id `live-probe`, one mode (programmer), defaults for the rest, the prompt from questions | each question and the summary | Clear questions, sensible defaults; `live-probe` in the temporary config.json and `roles/programmer/live-probe.md` |
| X7 | `~/.orca-roles/bin/e2e-browser.sh check` (or `install`); serve a page that sets a cookie (`python3 -m http.server 8765` in a folder with the index.html of `c_e2e`); in the project: `browser-login.sh http://127.0.0.1:8765/`, close the browser; `e2e-browser.sh session http://127.0.0.1:8765/`; write `qa-e2e/live/page.flow.js` (see `c_e2e`) and run `e2e-run.sh live --as default -- url=http://127.0.0.1:8765/` | each exit code | `Session saved: 1 cookies, 1 origins`; session exit 0; the flow passes and leaves `qa-evidence/live/report.json` |

## 2. A team in Orca (about 15 minutes)

| Id | Do | Look at | Expected |
|---|---|---|---|
| T1 | In Orca, create a worktree of the project with an agent (the composer: new worktree, pick Claude, any prompt) | the tabs that appear in the first minute; the kickoff log (`<git dir>/orca-roles-kickoff.log`) | Only the local coordinator's tab stays, plus your shell; the composer's extra agent tab is closed (note its title, and what the log says about it); the local coordinator asks which mode to use, naming programmer, pr-reviewer and academic-research |
| T2 | From a terminal of ANOTHER worktree, `cd` into the new worktree and run `roles --mode programmer` | its output and the tabs | "This terminal belongs to worktree ...; using the worktree of the current folder (...)"; Planner, Dev, Tester, Plan-Reviewer and Code-Reviewer open; the local coordinator gets its role message |
| T3 | `cat <git dir>/orca-roles.pty` and `orca terminal show --terminal <each handle> --json` | the ptyIds | Identical, byte for byte (on WSL they contain `\\wsl.localhost\...`) |
| T4 | `ps -o ni=,pid= -p <Tester's claude pid>` and its environment (`ps eww -p <pid>` on macOS, `/proc/<pid>/environ` on WSL) | nice and `OMP_NUM_THREADS` | `10` and `2` |
| T5 | Close the Dev's tab with its X, then run `roles` from macOS's Terminal app or another terminal outside Orca, `cd`'d into the worktree | the kickoff log; the local coordinator's tab | A new Dev tab; "Told the local coordinator the new handles."; the local coordinator sees a "Role handles changed" message; the kickoff log may also say "No Orca terminal identity here" |
| T6 | In the local coordinator's tab type `!~/.orca-roles/bin/launch.sh --mode pr-reviewer` and Enter | the tabs while it runs; the local coordinator's screen; how long it takes | Dev and Tester close quickly, the Plan-Reviewer and Code-Reviewer close and the Verifier opens for pr-reviewer, the local coordinator's conversation is cleared (Esc, `/clear`) and it gets "the mode was switched from programmer to pr-reviewer"; no tab left over; `orca-roles.switch-from` gone afterwards |
| T7 | The same back to `--mode programmer` | the same | The programmer team again, no leftover tab |
| T8 | In the local coordinator's tab type `!~/.orca-roles/bin/launch.sh --mode academic-research` and Enter | the same as T6 | The academic-research team opens, the local coordinator is cleared and gets its role message; no tab left over |
| T9 | The same back to `--mode programmer` | the same | The programmer team again, no leftover tab |
| T10 | `roles --open researcher` from a terminal of the worktree; look at its tab and `orca-roles.provenance.jsonl` | the tabs; the Researcher's model | The Researcher had no tab before; only it opens, the other tabs are as they were; it runs its configured model (Sonnet) |
| T11 | From a terminal in the project's main checkout, `orca terminal create --worktree current --title live-current --json`, then `pwd -P` in the new tab | the tab's folder | The main checkout |

## 3. A real restart (about 10 minutes)

Write down which tabs each worktree has, then restart Orca for real. Your own teams are affected too; afterwards run `roles` in each of them.

- macOS: Cmd+Q, then in macOS's Terminal app (not Orca) `pkill -f 'out/main/daem'`, then open Orca.
- WSL: close Orca and end every Orca process (Task Manager), or reboot Windows.

Do not click the throwaway worktree's tabs. Open one terminal of another worktree.

| Id | Do | Look at | Expected |
|---|---|---|---|
| R1 | `orca terminal list --worktree <throwaway worktree> --json` | which role tabs are listed | Usually only the shell and the worktree's active tab: the other role tabs are asleep (in the tab bar, not listed) |
| R1 | `cd` into the throwaway worktree and run `roles`; time it | its output | macOS: "Orca kept the tab of <Role> asleep after a restart; woke it." for each asleep role, then "reopening it with its conversation" for every role, no "no longer exists". WSL: the same messages; every role woken and reopened with its conversation, no "Cannot wake tabs" |
| R1 | Look at the tab bar; `orca terminal list` again; in each worker's tab, scroll up | duplicates; each worker's history | One tab per role, no stray "Claude Code" tab; each worker shows its earlier conversation; every handle in `orca-roles.env` answers `orca terminal show` |
| R1 | Before the restart: `orca orchestration run-create --from <local coordinator's handle> --objective "live checks R1: Run binding after a restart (throwaway)" --json`. After the restart and `roles`: `orca orchestration run-list --json` | that Run's `coordinator_handle` | The local coordinator's handle in `orca-roles.env` now, not the one before the restart |
| R2 | T3 again | the ptyIds | Identical |

On WSL also:

| Id | Do | Look at | Expected |
|---|---|---|---|
| W0 | `command -v orca; type orca; echo $ORCA_CLI_COMMAND; orca --version` | the chain | Note it: kit shim, orca-ide, bridge, orca.exe |
| W1 | Open a plain shell tab A in the throwaway worktree and type in it: `setsid sh -c 'sleep 5; orca terminal close --terminal <A> --tab --json; echo rc=$? > /tmp/close-a' >/dev/null 2>&1 &` | after a minute: does `/tmp/close-a` exist, is a `powershell.exe` still running for that close | Orca's behaviour, not the kit's: the file may never appear and powershell may keep running (the kit limits closes to 15 s, `ORCA_ROLES_CLOSE_TIMEOUT`, so it does not hang on it). Then close another tab B from a different terminal: it must return |

## 4. Other agents (someone with Codex or OpenCode)

Use a project whose `.orca-roles.json` puts the Planner and the Dev on `codex` (and the Tester on a custom `opencode` agent, `clearCommand` `/new`), with an MCP server `live-echo` (`command: cat`) given to the Dev; see `tests/live/agents.sh`.

| Id | Do | Look at | Expected |
|---|---|---|---|
| A1 | Open the team; wait a minute | each tab's title; `orca terminal show` agentIdentity | Titles stay "<Role> (codex)" / "(opencode)"; Orca recognizes the agent |
| A2 | `ps -o args= -p <Dev's codex pid>`; in the Dev's tab `/mcp` | the arguments; the list | `-c mcp_servers.live-echo...`; `/mcp` lists live-echo; `~/.codex/config.toml` unchanged |
| A3 | In the Dev's tab `/new`, then ask "Which role do you have in this team?" | the answer | "Dev" |
| A4 | `~/.orca-roles/bin/clean.sh tester` | the Tester's tab | `/new`, then its role message |
| A5 | The Codex Planner's arguments | superpowers | None (Claude only) |
| A6 | With the Code-Reviewer and the Researcher on OpenCode with the same neutral prompt, send both: "Use your subagent tool to list this folder, and do not list it any other way. Show the file names it returns. If that tool is refused or missing, reply with the word SUBAGENT, a hyphen, then the word REFUSED, with no spaces." | each tab's screen | The Researcher (no deny) lists the folder (if its tab shows its tool calls, one of them is its subagent tool); the Code-Reviewer replies SUBAGENT-REFUSED and lists nothing |

## 5. A hidden role (about 30 minutes)

No script runs these yet. Run by hand on 2026-11-02: HR0, HR1 and HR2 (all as expected). HR3 to HR6 have not been run yet. They check a role with `"open": "hidden"` (`bin/hidden-role.sh`) under a real `claude -p` and a real local coordinator.

Setup:
- Create a new worktree of the throwaway project, as in T1, and do not answer the mode question until the `jq` below is done.
- In its shell tab, make the Researcher hidden on the cheap model: `jq '.roles.researcher = {enabled: true, open: "hidden", model: "claude-haiku-5-5"}' .orca-roles.json > .orca-roles.json.new && mv .orca-roles.json.new .orca-roles.json`. Only the worktree's copy changes, and it goes with the worktree. The worktree already has a `.orca-roles.json`: edit it with this `jq` command, never write the file with `echo >`, which erases its other settings.
- If the mode was already answered: run the `jq`, then `~/.orca-roles/bin/launch.sh --mode programmer` (it reports the hidden role but does not resend the coordinator's message), then in the coordinator's tab type `/clear` and ask it to run `~/.orca-roles/bin/clean.sh --msg local-coordinator` and follow what it prints.

How to run them:
- A hidden role has one run at a time, so wait for each message before the next task.
- The local coordinator needs a Run bound before the first task: ask it to create one for the worktree and link it with run-use. Without one the `Hidden role done` message is stored under `run_unbound` and is never pushed to it: it only sees the result when you write to it.
- A command shown as `!...` is typed in the local coordinator's tab, which runs it in the worktree. Type one `!` command per message; several `!` commands pasted together fail.
- `<hd>` stands for `"$(git rev-parse --git-dir)/orca-roles-hidden"`, typed as it is.
- Each report is `~/.orca-roles/tmp/<project>-<hash>/researcher/hidden-<tag>.md`, and each message names its own.

| Id | Do | Look at | Expected |
|---|---|---|---|
| HR0 | In the worktree's shell, after the `jq` above: `~/.orca-roles/bin/launch.sh --mode programmer`, then `~/.orca-roles/bin/hidden-role.sh --status` | the output; the tabs; the local coordinator's role message | "Hidden (no tab; the local coordinator runs each with hidden-role.sh): Researcher (researcher)."; Planner, Dev, Tester, Plan-Reviewer and Code-Reviewer open, no Researcher tab; the role message says "Hidden roles, with no tab, run with hidden-role.sh (see "The team" in your prompt): Researcher (researcher)."; `--status` prints nothing |
| HR1 | Ask the local coordinator for three one-line Researcher tasks, one at a time: tag `h2-t1` (what README.md says), `h2-t2` (how many files git tracks), `h2-t3` (the current branch). While one runs: `!~/.orca-roles/bin/team-status.sh` | the coordinator's tab; each message; team-status | Before the first task it reads `local-coordinator-hidden.md`; it writes a brief, runs `~/.orca-roles/bin/hidden-role.sh researcher --brief <file> --tag <tag>` without asking you ("Started Researcher hidden (<tag>); log: ...") and ends its turn; team-status shows `hidden-running`; each run ends in one `Hidden role done` whose first line is `role=researcher tag=<tag> outcome=done marker=ok session=<id> wall=<seconds> report=<file>`; the coordinator reads the report and gives you the right answer |
| HR1 | For each tag: `!head -n 3 ~/.orca-roles/tmp/*/researcher/hidden-<tag>.md`; `!jq '{session_id, is_error, models: (.modelUsage \| keys), permission_denials}' <hd>/<tag>.json`; `!H=<hd>; head -c 500 "$H/<tag>.prompt"; s="$(jq -r .session_id "$H/<tag>.json")"; grep -o '"file_path":"[^"]*\.md"' "$(find "$HOME/.claude/projects" -name "$s.jsonl" \| head -n 1)" \| sort -u` | the marker; the model; the role's files | The report's first word is `Done`; `is_error` false, models `["claude-haiku-5-5"]`; every file the prompt's "Read ... and adopt that role" names is in the list of files read. A `marker=missing` or an unread file is written down, not a failure: note whether the coordinator told you, did not accept the run as it was, recommended a fresh run (same brief, new tag, no `--resume`) and waited for your yes |
| HR2 | Ask the coordinator for a Researcher task with tag `h2-q` that needs a colour nobody gave it, and must ask for it rather than choose one. When the question comes, give the coordinator the answer (green) with tag `h2-q2`. Then `!H=<hd>; jq -r .session_id "$H/h2-q.json" "$H/h2-q2.json"` and `!head -c 300 <hd>/h2-q2.prompt` | the messages; the two outputs | `Hidden role question` with `outcome=question`, and the report's last line starts with `QUESTION: `; the coordinator runs `hidden-role.sh researcher --brief <answer file> --tag h2-q2 --resume <session>`; then `Hidden role done`, `outcome=done`, the colour in the report; the two session ids are the same; the h2-q2 prompt is the answer and the closing line, with no "Read ... and adopt that role" |
| HR3 | Ask the coordinator for a Researcher task with tag `h2-stop` that runs `sleep 240` in the foreground with a Bash timeout of 300000 ms. When `!~/.orca-roles/bin/hidden-role.sh --status; pgrep -fl 'sleep 240'` shows `running researcher h2-stop` and the sleep: `!~/.orca-roles/bin/hidden-role.sh --stop researcher`. Then `!~/.orca-roles/bin/hidden-role.sh --status; ls <hd>; pgrep -fl 'sleep 240'` | the output; the messages; the last three outputs | `Stopped researcher`; one message, `Hidden role done` with `outcome=failed`, `marker=missing` and the text `stopped` (`session=-`, or an id: note it); `--status` prints nothing; no `researcher.pid` or `researcher.stop` in `<hd>`; no `sleep 240` left. Note what the coordinator does with this `marker=missing` |
| HR4 | Ask the coordinator for a Researcher task with tag `h2-orca` that runs `orca --version` and copies its output, or the refusal, into the report, trying no other way. Then `!jq '.permission_denials' <hd>/h2-orca.json` | the report; the output | One message (`outcome` done or failed); the report says the command was denied and shows no Orca version; `permission_denials` holds an entry with `"tool_name": "Bash"` whose command holds `orca --version`; the coordinator got no other message |
| HR5 | Ask the coordinator for a Researcher task with tag `h2-kill`, the same as `h2-stop`. When `!cat <hd>/researcher.pid` shows five fields, the first a number: `!f=<hd>/researcher.pid; kill -9 "$(cut -d' ' -f3 "$f")"; kill -TERM -- "-$(cut -d' ' -f1 "$f")"`. Wait a full minute, then `!~/.orca-roles/bin/hidden-role.sh --status`. Then tell the coordinator "the result of h2-kill did not arrive", and run `--status` again after it acts | the messages; both `--status` outputs; the coordinator | No message arrives; `--status` prints `lost researcher h2-kill <hd>/h2-kill.log`; the coordinator runs `hidden-role.sh --status`, treats the run as a failed task, looks at what it left in the worktree and runs `hidden-role.sh --ack h2-kill`; the second `--status` prints nothing |
| HR6 | `!~/.orca-roles/bin/usage-metrics.sh --once; echo rc=$?`, then for `h2-t1` and for `h2-q`: `!s="$(jq -r .session_id <hd>/<tag>.json)"; grep -h "\"session_id\":\"$s\"" ~/.orca-roles/metrics/sessions-*.jsonl \| tail -n 1 \| jq '{session_id, orca_roles_role, project, cost, models: (.models \| keys)}'` | the outputs | `rc=0`; for each session `orca_roles_role` is `researcher`, `project` is the throwaway project, `cost` is above 0, models `["claude-haiku-5-5"]`; h2-q and h2-q2 are one session. If a session prints nothing: `!grep -c "$(pwd -P)" ~/.orca-roles/metrics/worktrees.jsonl` |

To finish:
- `!~/.orca-roles/bin/hidden-role.sh --status` prints nothing. For any `undelivered` or `lost` line, run `!~/.orca-roles/bin/hidden-role.sh --ack <tag>`.
- `!ps -axo pid,pgid,command | grep -E 'hidden-role.sh --supervise|output-format json|sleep 240' | grep -v grep` prints nothing.
- Run `!rm -rf <hd> ~/.orca-roles/tmp/*/researcher/hidden-h2-*.md`.
- Delete the worktree in Orca. `git -C ~/orca-live-checks/project worktree list` then lists only the main checkout.

## Results

Copy this table and fill it; send it to the Planner with anything odd you saw.

| Id | OK / FAIL / skipped | Notes (what you saw, timings, titles) |
|---|---|---|
| X1 | | |
| X2 | | |
| X3 | | |
| X4 | | |
| X5 | | |
| X6 | | |
| X7 | | |
| T1 | | |
| T2 | | |
| T3 | | |
| T4 | | |
| T5 | | |
| T6 | | |
| T7 | | |
| T8 | | |
| T9 | | |
| T10 | | |
| T11 | | |
| R1 | | |
| R2 | | |
| W0 | | |
| W1 | | |
| A1-A6 | | |
| HR0 | | |
| HR1 | | |
| HR2 | | |
| HR3 | | |
| HR4 | | |
| HR5 | | |
| HR6 | | |
