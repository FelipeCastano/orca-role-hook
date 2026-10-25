# Live checks

What the smoke tests (`tests/smoke.sh`) cannot cover, because it needs a real Orca, real agents, the network or a person, collected from the "Not verified" sections of the merged pull requests (#1-#45), this PR and `BACKLOG.md`. Each item is covered by one of three scripts, or listed at the end as behaviour that can only be observed in normal use.

## How to run them

Install the checkout you want to check (`./install.sh`), then run the script from an Orca terminal of that checkout. Each script:

- works in a throwaway project, `~/orca-live-checks/project` (registered in Orca once and reused), with a cheap team (Planner, Dev, Tester and Auditor on `claude-haiku-5-5`; override with `ORCA_LIVE_MODEL`). Your own teams are never touched, except by the Orca restart that `mac.sh` and `wsl.sh` ask for;
- asks you only for what a script cannot do (close a browser window, answer the new-role wizard, restart Orca); type `skip` at a prompt to skip that check;
- writes one report, `~/orca-live-checks/report-<script>.md`: one row per check (OK, FAIL, INFO, SKIP) plus the logs of the failures. Send it to the Planner.

A check already done is not repeated when you run the script again. To start over: `rm ~/orca-live-checks/state-<script>`.

| Script | Who | Steps |
|---|---|---|
| `tests/live/mac.sh` | macOS, Claude Code | Run it; at the end it asks for a real restart of Orca (Cmd+Q, then `pkill -f 'out/main/daem'` in macOS's Terminal app). Reopen Orca, open one terminal of this checkout (do not click the live-checks worktree's tabs) and run it again. |
| `tests/live/wsl.sh` | Windows + WSL, Claude Code | The same; the restart is closing Orca and ending every Orca process (Task Manager, or a Windows reboot). |
| `tests/live/agents.sh` | Anyone with Codex and/or OpenCode signed in | One run, no restart; Claude Code is not needed. |

After the restart run `roles` in each of your own worktrees: the installed kit wakes their tabs too.

## What each script checks

### mac.sh and wsl.sh

| Id | What it proves | From |
|---|---|---|
| X1 | The smoke sections that once failed together (`launch restart reopen wake worktree-select`) pass in one run | #29 |
| X2 | `upgrade_config` on a user config without a `roles` key. Expected FAIL today ("null has no keys"): a known bug, left for a later PR | #37 |
| X3 | `scholar.sh` against the live APIs: OpenAlex, arXiv (one word and a phrase), Semantic Scholar (with `S2_API_KEY` if set), Crossref and DataCite DOIs through doi.org, `verify`, a real PDF download under the size limit. Known FAIL: a several-word arXiv search returns nothing | #28 |
| X4 | `roles-yaml --all --dry-run` over the projects registered in your Orca; nothing is written | #32 |
| X5 | A fresh install into a temporary HOME: the real superpowers fetch from GitHub, a Claude session that loads its skills, and `project-plugins.sh install` doing a real `claude plugin marketplace add` and `install` (in a temporary Claude config) | #39 |
| X6 | The new-role wizard typed by you, in that temporary kit | #28 |
| X7 | The pinned E2E stack: install, `browser-login.sh` saving a real session (a local page sets a cookie and localStorage), `e2e-browser.sh session`, and `e2e-run.sh` running a flow with that session against the page | #31 |
| T1 | A worktree created by Orca with an agent: the setup script runs the kit, only the Planner opens and asks the mode; the composer's extra session (its title is reported) is closed | #1, #45 |
| T2 | Choosing the mode from a terminal of another worktree: the kit takes the folder's worktree and opens the programmer team | #45, this PR |
| T3 | `orca-roles.pty` holds Orca's ptyId byte for byte (on WSL the ptyIds have backslashes) | this PR |
| T4 | The Tester's agent runs at nice 10 with its thread caps | #8 |
| T5 | A worker reopened while the Planner keeps its tab: kickoff's background shell sends "Role handles changed" | #29 |
| T6, T7 | A mode switch typed in the Planner's own tab, to pr-reviewer and back: old workers closed, Esc + clear while kickoff runs, the new role message, no leftover tab, how long it took | #45 |
| R1 | After a real restart: which role tabs Orca left asleep, `roles` wakes them (macOS; on WSL it says it cannot yet), every role reopens with its conversation, no duplicate tab, every saved handle is live, how long it took | this PR, #8, #38, BACKLOG |
| R2 | T3 again after the restart | this PR |

### wsl.sh only

| Id | What it proves | From |
|---|---|---|
| W0 | How the `orca` CLI is reached from WSL (`$ORCA_CLI_COMMAND`, the bridge) | #19 |
| W1 | The Planner relauncher's hang: a process started in a tab and detached with `setsid` closes that same tab; does the close return? And closing another tab from this terminal | WSL bug report |

### agents.sh

| Id | What it proves | From |
|---|---|---|
| A1 | Codex and OpenCode keep the kit's tab title ("<Role> (codex)", "(opencode)") and Orca recognizes the agent | #43, BACKLOG |
| A2 | Codex gets a role's MCP servers as `-c` overrides, `/mcp` lists them, `~/.codex/config.toml` is untouched | #1 |
| A3 | After `/new` Codex keeps its developer instructions (it still names its role) | #14 |
| A4 | OpenCode as a custom agent: `clean.sh` clears it and resends its role | #14 |
| A5 | A Codex Planner starts without superpowers (Claude only) | #39 |

## Not scriptable: observed in normal use

These depend on how a live model applies the prompts, or on services the scripts do not have. Note anything odd in a session and tell the Planner.

- The Planner re-reads the history before each step and waits for the user's yes before every commit and push (#22); it shows the text and waits before writing to Jira or GitHub (#8).
- Workers follow the report rules (#32) and stop after their `worker_done` (this PR); briefs name only the affected tests (#40).
- The Planner reads a project's conventions and the Auditor checks plans against a plan gate on a real repo (#41); the plan passes and "Rulings I made" (#42).
- academic-research workers on a real experiment, a data download or an HPC submission (#28, #37).
- Codex workers never open `request_user_input` (#38: they rely on the prompt rule).
- `glab` and JQL against a real GitLab and Jira (#22).
- The MCP of the E2E-Tester reconnecting after its tab is reopened (#31).

## Dropped: no longer applies

| Item | Why |
|---|---|
| CI on macOS runners (#1) | CI runs on macOS on every pull request |
| Step discipline with an Auditor and a commit per step (#7) | Replaced by one audit per set (#25) and commits at set close (#29) |
| Restart with memory and no duplicates (#8) | Replaced by R1 (asleep tabs, this PR) |
| The general step definition's wording (#22) | The flow was rewritten later |
| The kickoff's EXIT trap on bash 5 (#30) | CI's Ubuntu run uses bash 5 on every pull request |
| A launch abort seen once in a mutant run (#30) | Never reproduced; nothing to script |
| `cat .../launch.sh` counting as a launch (#19) | Accepted as harmless |
| A NUL byte in a title (#44) | Cannot reach agent.sh through the JSON configuration |
| The academic-research wording-only guard, the `.git` check, the suite depending on `ORCA_ROLES_CONFIG` (#40-#42) | Fixed and tested in this PR |
| A real kit update with an academic-writer team open (#33) | The install never touches open tabs, and the old mode id of a saved team is covered by the smoke tests; the alias goes away after the next tag |
