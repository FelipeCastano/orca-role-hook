# Manual checks

The same checks as the live scripts (`docs/live-checks.md`), as a guide to follow by hand: what to do, what to look at, what to write down. Use it when you want to see each step yourself, or when a script's check fails and you want to repeat it. The ids are the scripts' ids.

Before you start:

- Install the checkout you want to check: `cd <checkout> && ./install.sh`.
- Use a throwaway project, never one of your teams: `~/orca-live-checks/project` if a script already created it; otherwise create a git repo with one commit, add it to Orca (`orca repo add --path <folder>`) and run `roles-yaml` in it (no `--mode`, so new worktrees ask the mode).
- Give it a cheap team: an `.orca-roles.json` with `claude-haiku-5-5` for planner, dev, tester and auditor, and researcher, e2e-tester and deployer disabled (the scripts' project has one).
- Keep a copy of the results table at the end and fill it as you go.

On WSL do the same steps; where a step differs, it says so. The kit's shim is `~/.orca-roles/shim/orca`: if `orca` is not found in a WSL terminal, put `~/.orca-roles/shim` first in your PATH (the scripts do it themselves).

## 1. Without Orca (about 10 minutes)

| Id | Do | Look at | Expected |
|---|---|---|---|
| X1 | `tests/smoke.sh launch restart reopen wake worktree-select` | the last line | `ALL OK` |
| X2 | `bash -c '. bin/lib.sh; upgrade_config config.default.json <(echo "{}") .'` | the output | Today: `null (null) has no keys` (known bug, #37). Note it if it changes |
| X3 | `~/.orca-roles/bin/scholar.sh search "transformer" --source arxiv --limit 2`, the same with `"attention is all you need"`, then `--source openalex` and `--source s2`; `scholar.sh show 10.1038/nature14539`; `scholar.sh bibtex 10.48550/arXiv.1706.03762` | results per source | Rows for each source. Known: the several-word arXiv search returns only the header; Semantic Scholar may fail without `S2_API_KEY` |
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
| T1 | In Orca, create a worktree of the project with an agent (the composer: new worktree, pick Claude, any prompt) | the tabs that appear in the first minute; the kickoff log (`<git dir>/orca-roles-kickoff.log`) | Only the Planner's tab stays, plus your shell; the composer's extra agent tab is closed (note its title, and what the log says about it); the Planner asks which mode to use, naming programmer, pr-reviewer and academic-research |
| T2 | From a terminal of ANOTHER worktree, `cd` into the new worktree and run `roles --mode programmer` | its output and the tabs | "This terminal belongs to worktree ...; using the worktree of the current folder (...)"; Planner, Dev, Tester and Auditor open; the Planner gets its role message |
| T3 | `cat <git dir>/orca-roles.pty` and `orca terminal show --terminal <each handle> --json` | the ptyIds | Identical, byte for byte (on WSL they contain `\\wsl.localhost\...`) |
| T4 | `ps -o ni=,pid= -p <Tester's claude pid>` and its environment (`ps eww -p <pid>` on macOS, `/proc/<pid>/environ` on WSL) | nice and `OMP_NUM_THREADS` | `10` and `2` |
| T5 | Close the Dev's tab with its X, then `roles` from a terminal of the worktree | the kickoff log; the Planner's tab | A new Dev tab; "Told the Planner the new handles."; the Planner sees a "Role handles changed" message |
| T6 | In the Planner's tab type `!~/.orca-roles/bin/launch.sh --mode pr-reviewer` and Enter | the tabs while it runs; the Planner's screen; how long it takes | Dev and Tester close quickly, the Auditor reopens for pr-reviewer, the Planner's conversation is cleared (Esc, `/clear`) and it gets "the mode was switched from programmer to pr-reviewer"; no tab left over; `orca-roles.switch-from` gone afterwards |
| T7 | The same back to `--mode programmer` | the same | The programmer team again, no leftover tab |

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
| R1 | | |
| R2 | | |
| W0 | | |
| W1 | | |
| A1-A5 | | |
