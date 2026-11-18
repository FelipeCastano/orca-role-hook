# Live checks

What the smoke tests (`tests/smoke.sh`) cannot cover, because it needs a real Orca, real agents, the network or a person, collected from the "Not verified" sections of the merged pull requests (#1-#45), this PR and `BACKLOG.md`. Each item is covered by one of three scripts, or listed at the end as behaviour that can only be observed in normal use.

## How to run them

To follow the same checks by hand instead, step by step, use [manual-checks.md](manual-checks.md).


Install the checkout you want to check (`./install.sh`), then run the script from that checkout (`cd` into it) in any terminal, with Orca open. Each script:

- works in a throwaway project, `~/orca-live-checks/project` (registered in Orca once and reused), with a cheap team (local coordinator, Planner, Dev, Tester, Plan-Reviewer and Code-Reviewer on `claude-haiku-5-5`; override with `ORCA_LIVE_MODEL`; the Researcher stays on its own model and opens on first use). Your own teams are never touched, except by the Orca restart that `mac.sh` and `wsl.sh` ask for;
- asks you only for what a script cannot do (close a browser window, answer the new-role wizard, restart Orca), and only when it runs with a terminal (without one, X6 feeds the wizard from a file and X7 skips what needs a person); type `skip` at a prompt to skip that check;
- writes one report, `~/orca-live-checks/report-<script>.md`: one row per check (OK, FAIL, INFO, SKIP) plus the logs of the failures. Send it to the Planner;
- records how long each check took, and how long it waited for you at a prompt, in `~/orca-live-checks/timings-<script>.tsv` (one line per check run, one `# run` line per run of the script), so a slow check shows without timing it again.

The scripts put the kit's shim (`~/.orca-roles/shim`) first in their PATH themselves when `orca` is not found, so a plain WSL terminal needs no PATH setup.

A check already done is not repeated when you run the script again. To start over: `rm ~/orca-live-checks/state-<script>`. A later run also reuses the worktree of the earlier one, which keeps the team it opened with: after the kit's roles or a script's team change, start over.

| Script | Who | Steps |
|---|---|---|
| `tests/live/mac.sh` | macOS, Claude Code | Run it; at the end it asks for a real restart of Orca (Cmd+Q, then `pkill -f 'out/main/daem'` in macOS's Terminal app). Reopen Orca, open one terminal of this checkout (do not click the live-checks worktree's tabs) and run it again. |
| `tests/live/wsl.sh` | Windows + WSL, Claude Code | The same; the restart is closing Orca and ending every Orca process (Task Manager, or a Windows reboot). |
| `tests/live/agents.sh` | Anyone with Codex and/or OpenCode signed in | One run, no restart; Claude Code runs the local coordinator, the other roles of the check run on those agents. Set `ORCA_LIVE_OPENCODE_MODEL=<provider/model>` when OpenCode's default model does not work on your machine (the OpenCode roles use it). |

After the restart run `roles` in each of your own worktrees: the installed kit wakes their tabs too.

### Running one check

To run a single check without the whole script, from the checkout in bash, after `./install.sh` of that checkout, with Orca open: source `tests/live/lib.sh`, run `live_start <name>` and `live_preflight`, then `run_check <id> <function> [args]`. For example:

```sh
bash -c '. tests/live/lib.sh; live_start wsl; live_preflight; run_check X7 c_e2e'
```

- The function and the arguments of each id are on its `run_check` line in `live_main` (`tests/live/lib.sh`), or in `tests/live/wsl.sh` for W0-W2.
- `live_start <name>` picks the report and the state files (`report-<name>.md`, `state-<name>`). With a script's own name (`mac`, `wsl`) the rows are added to that script's report, and a check already done there is skipped; to run it again, delete its `done.<id>=1` line from `~/orca-live-checks/state-<name>`, or use another name for a separate report and state.
- What a check needs before it: X7 needs the throwaway project (`project_setup`, already there after a full run). T2-T11 need the worktree T1 created, loaded with `wt_load` from the same state file (`live_start` with the name of the run that ran T1). R1 and R2 need the restart phase and are not run alone.
- `ORCA_LIVE_DIR` moves the folder (default `~/orca-live-checks`).

## What each script checks

### mac.sh and wsl.sh

| Id | What it proves | From |
|---|---|---|
| X1 | The smoke sections that once failed together (`launch launch-mode launch-add restart reopen wake worktree-select`) pass in one run; it honours `SMOKE_JOBS` (default 1) | #29 |
| X2 | `upgrade_config` on a user config without a `roles` key (or with `"roles": null`): it returns the upgraded config with the default roles | #37 |
| X3 | `scholar.sh` against the live APIs: OpenAlex, arXiv (one word and a phrase), Semantic Scholar (with `S2_API_KEY` if set), Crossref and DataCite DOIs through doi.org, `verify`, a real PDF download under the size limit | #28 |
| X4 | `roles-yaml --all --dry-run` over the projects registered in your Orca; nothing is written; fails when every project was skipped | #32 |
| X5 | A fresh install into a temporary HOME: the real superpowers fetch from GitHub, a Claude session that loads its skills, and `project-plugins.sh install` doing a real `claude plugin marketplace add` and `install` (in a temporary Claude config) | #39 |
| X6 | The new-role wizard in that temporary kit: typed by you, or fed from a file when there is no terminal | #28 |
| X7 | The pinned E2E stack: install, `browser-login.sh` saving a real session (a local page sets a cookie and localStorage), `e2e-browser.sh session`, and `e2e-run.sh` running a flow with that session against the page; it asks before opening the browser, and without a terminal the login, session and flow are skipped. An environment failure (the install, the local server, or the browser start) also leaves X7 not done, so a later run asks for it again | #31 |
| T1 | A worktree created by Orca with an agent: the setup script runs the kit, only the local coordinator opens and asks the mode; the composer's extra session (its title is reported) is closed | #1, #45 |
| T2 | Choosing the mode from a terminal of another worktree: the kit takes the folder's worktree and opens the programmer team | #45, this PR |
| T3 | `orca-roles.pty` holds Orca's ptyId byte for byte (on WSL the ptyIds have backslashes) | this PR |
| T4 | The Tester's agent runs at nice 10 with its thread caps | #8 |
| T5 | A worker reopened while the local coordinator keeps its tab, with `roles` run with no Orca identity (as from a terminal outside Orca): kickoff sends "Role handles changed" | #29, this PR |
| T6, T7 | A mode switch typed in the local coordinator's own tab, to pr-reviewer and back: old workers closed, Esc + clear while kickoff runs, the new role message, no leftover tab, how long it took | #45 |
| T8, T9 | The same switch to `academic-research` and back to programmer | #58 |
| T10 | A first-use role: `launch --open researcher` opens only it, the other tabs stay as they were, and it runs its configured model (the Researcher on Sonnet) | #58 |
| T11 | `orca terminal create --worktree current` from a main checkout opens the terminal in that checkout | #58 |
| R1 | After a real restart: whether the wake path is available (an INFO row: Orca's runtime client, or why it is missing), which role tabs Orca left asleep, `roles` wakes them (macOS and WSL), every role reopens with its conversation (counted by the conversation-keeping wording), no role starts without memory, no duplicate tab, every saved handle is live, how long it took, and the local coordinator's Run (its own, or a throwaway one when it has none) is bound to its new tab (SessionStart hook, or the kickoff's run-use reminder) | this PR, #8, #38, BACKLOG |
| R2 | T3 again after the restart | this PR |

### wsl.sh only

| Id | What it proves | From |
|---|---|---|
| W0 | How the `orca` CLI is reached from WSL (`$ORCA_CLI_COMMAND`, the bridge) | #19 |
| W1 | The Planner relauncher's hang: a process started in a tab and detached with `setsid` closes that same tab; does the close return? And closing another tab from this terminal. It measures Orca's behaviour and stays FAIL while Orca hangs; the kit no longer hangs on it because it limits closes to 15 s (`ORCA_ROLES_CLOSE_TIMEOUT`) | WSL bug report |
| W2 | `capacity.sh --json` in the WSL VM: the OS kind and whether it is `wsl`, the available memory, the pairs it fits and what it says it does not measure | this PR |

### agents.sh

| Id | What it proves | From |
|---|---|---|
| A1 | Orca recognizes Codex and OpenCode as agents (`agentIdentity`); whether each kept the kit's tab title ("<Role> (codex)", "(opencode)") is reported, and a title the agent changes is not a failure | #43, BACKLOG |
| A2 | Codex gets a role's MCP servers as `-c` overrides, `/mcp` lists them, `~/.codex/config.toml` is untouched | #1 |
| A3 | After `/new` Codex keeps its developer instructions (it still names its role) | #14 |
| A4 | OpenCode as a custom agent: `clean.sh` clears it and resends its role | #14 |
| A5 | A Codex Planner starts without superpowers (Claude only) | #39 |
| A6 | OpenCode runtime deny of subagents: the same request with the same neutral prompt; a role with no deny lists the folder (the control; the screen does not show that its subagent did it), the Code-Reviewer replies that its subagent tool is refused and lists nothing | #58 |

## Manual checklist

For the person running the checks; each line says what to do and what to see.

- **G. Restart note after an update.** Run `./install.sh` while a team is open, then `roles`: the note asks to restart the open tabs.
- **H. On-demand Auditor on real data.** Run `auditor` in the global coordinator's folder and ask it to audit the roles of a real worktree: it reports problems and proposals and changes no file.
- **I. The Researcher on Sonnet on a real task.** Give the Researcher a real research question through the local coordinator: its tab opens on first use, it answers within its brief, its report starts with `Done`.
- **J. A hidden role.** Section 5 of [manual-checks.md](manual-checks.md) (HR0-HR6): a role with `"open": "hidden"` run by a real local coordinator, with its question, `--resume`, `--stop`, the `orca` deny, a killed supervisor and usage metrics.
- **K. Automatic reopen of the coordinated worktrees' teams after a restart.** A person, through a real global coordinator. This is the first real check of `launch.sh id:<worktree> --reopen` started from a detached process with the coordinator tab's environment (the smoke tests cover the script and the hook with a fake Orca and a stub `launch.sh`). Precondition: the global coordinator was started by this version's `coordinator.sh`; a session started by an older one gets no automatic reopen. With a global coordinator managing at least one worktree with an open team, restart Orca as `mac.sh`/`wsl.sh` describe, reopen the coordinator's tab, and check: the SessionStart line in its tab that says the teams are being reopened in the background; `~/.orca-roles/state/reopen-teams.last` with that worktree `reopened` (and any role named after "without memory"); the worktree's local coordinator back with its conversation and the kit's settings; whether the "Teams reopened" status was shown in the coordinator's tab (Orca does not always announce it: record which); a reopen started by a coordinator's tab touches only that coordinator's worktrees (the `Scope:` line and the `other-coordinator` lines in `~/.orca-roles/state/reopen-teams.log`; a worktree whose Run nothing records as that coordinator's is `unbound-run` and is named in `reopen-teams.last`; `reopen-teams.sh --coordinator <handle>` scopes a manual run the same way); a working role (Claude and OpenCode) is kept, each with its `keeping it` line; a second coordinator's tab coming back minutes later does not close the first coordinator's roles; no duplicate tab; the reopened local coordinator's record in `~/.orca-roles/state/session-handles/` has no second line `coordinator`. On WSL the same with `wsl.sh`'s restart.
- **L. No trust dialog for the kit's folders.** A person, with a real Orca and Claude Code. Before this change (Claude Code 2.1.326), each new Claude role showed one "Adding a new directory" dialog per kit folder passed with `--add-dir`: two for a role without `{kit}` in `extraDirs` (`~/.orca-roles/prompts` and its scratch folder; seen on 2026-11-17 for a Plan-Reviewer, whose role message and first kickoff were lost), three for the local coordinator and the Planner (also `~/.orca-roles`). Answering the dialog writes no trust record, so it came back for every new role. Steps: with `jq`, check that the `.claude.json` of the Claude Code profile in use (under Orca, the Orca profile's `CLAUDE_CONFIG_DIR`; otherwise `~/.claude.json`) has no `projects` record for `~/.orca-roles`, `~/.orca-roles/prompts` or the new worktree's scratch folders (a new worktree's scratch folders never have one, so they are the deciding observation even on a profile used before); then open a new worktree's team (the Planner, the local coordinator and at least one more Claude worker), the Auditor and the global coordinator. See: no "Adding a new directory" dialog in any tab; each tab shows its role's first reply to the kickoff (the role message reached the prompt, nothing was typed into a dialog); a worker writes its report in its scratch folder without a permission question; the profile's `.claude.json` still has no record for those folders. If a trust dialog for the worktree folder itself appears (Claude Code's own project trust, not a kit folder), note it: it is outside this check. Record the Claude Code version it was run with.

## Not scriptable: observed in normal use

These depend on how a live model applies the prompts, or on services the scripts do not have. Note anything odd in a session and tell the Planner.

- The Planner re-reads the history before each step and waits for the user's yes before every commit and push (#22); it shows the text and waits before writing to Jira or GitHub (#8).
- Workers follow the report rules (#32) and stop after their `worker_done` (this PR); briefs name only the affected tests (#40).
- The Planner reads a project's conventions and the Plan-Reviewer checks plans against a plan gate on a real repo (#41); the plan passes and "Rulings I made" (#42).
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
