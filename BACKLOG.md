# Backlog

Known pending work for the kit. Each entry says what to do and why; remove it when done.

## Ideas

- **Run one check or one group of checks of a smoke section.** A section is one function whose checks depend on fixtures, fakes and result strings defined earlier in it, and a check has no name to select; it needs a name per group, each group's fixture prefix and an explicit reset at its start. Today the unit is the section (`tests/smoke.sh <section>`).

- **T5 and the Run coordinator keeping an old Planner handle.** Planned for the next PR ("handles").
- **`upgrade_config` with a config that has no `roles` key** (X2 of the live checks).
- **arXiv search with several words** in `scholar.sh`.
- **The installer leaves `prompts/academic-writer` behind** after the role was removed or renamed.
- **CI check of the `plugin.json` version** against the kit's version.
- **An extra agent tab after a mode switch typed in the Planner's tab** (T6/T7 of the live checks). The checks now attach the worktree's terminals when it happens; find the cause from that output.
- **Tabs Orca resumes by itself lack the kit's shim in their PATH** until `roles` reopens them.
- **Windows-side processes of an `orca` call the kit killed at its time limit** (WSL). Whether any stays running is not verified.
- **One time-limited runner.** `oc_bounded` and `run_limited`/`orca()` in bin/lib.sh, `bounded` in models.sh, review-skill.sh and project-plugins.sh, the sleeper in crosscheck.sh `run`, `limited` in metrics.sh and the poll in agent.sh `record_provenance` each run a command with a time limit and differ in killing descendants, reporting the timeout and counting ticks against the clock; one `bounded_run` in lib.sh would serve all.
- **Coordinator needs Orca's nested worker depth 2** (Settings → Orchestration → "Nested worker depth", default 1); check it at `coordinator.sh` start instead of only documenting it.
- **Cost figures from Orca's cost state** are 12-22 % above the sums of the transcripts, and unknown after `--resume`; find out which is right before relying on them.
- **The oracle does not follow `npm ci` install hooks** (`preinstall`, `install`, `postinstall`, `prepare`) and does not match a runner `.sh` whose path has a space or a character outside `[A-Za-z0-9_./-]` (the path patterns stop there; git also quotes non-ASCII paths in its diff output); both are cheat routes it does not report.
- **The oracle's integrity check misses two routes.** A tracked test file replaced by a symlink (git status T) is neither deleted nor modified for the check; a new `conftest.py` hidden by `.git/info/exclude` or another ignore file is not listed (only untracked, not ignored, files are seen). A package script running its `.sh` as `bash -o pipefail x.sh` (an option with an argument), `bash --norc x.sh` (a long option) or `CI=1 x.sh` (an environment prefix) is only listed, not a cheat.
- **The oracle's spec file is writable by workers.** The Planner saves each Dev spec under its scratch folder in `~/.orca-roles/tmp/`, which workers may write (only the kit's own files are protected, and Edit-only for Claude); a Dev could change the acceptance command before the oracle reads it. Keep the spec outside workers' reach or check its hash against the dispatched task's spec.
- **bin/oracle/__pycache__ left in the worktree** by the smoke's oracle sections; set `PYTHONDONTWRITEBYTECODE=1` for the oracle's python (oracle.sh or the suite).

## Pending verification

- **Codex and OpenCode tab titles.** The kit titles each role's tab with the agent's name ("Researcher (codex)") so Orca recognizes it as an agent (stablyai/orca#32090). Claude Code is kept from retitling its tab with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`; whether Codex and OpenCode retitle their tab, and with what switch to stop it, is unverified (for Codex, `[tui] terminal_title` in `~/.codex/config.toml`, see stablyai/orca#26557). Verify without driving the agents interactively. For OpenCode, also with Orca 1.4.239 and `orca orchestration dispatch --inject` (the kit's OpenCode dispatch path).
- **The tab-title fix on Windows + WSL.** Verified on macOS only, including a simulated Ubuntu `.bashrc` that retitles the tab at its prompt (the kit sets its title again before starting the agent). Confirm on WSL that `worker-start --terminal <role>` is accepted after `roles`.
- **WSL: stale handles after an Orca restart.** On WSL, `orca-roles.env` kept old handles for every role but one after Orca restarted, and the "Roles reopened" message carried them. Not reproduced on macOS. A side effect seen there: `relaunch-role.sh` reopened the whole team, because the other roles' tabs counted as "closed but Orca kept its session running".
- **Real OpenCode permission semantics.** The kit's OpenCode permissions (allow-all first, the role's items, then the kit's denies; `subagent` deny for the Auditor) rely on OpenCode 2.0.25's source: the last matching rule wins and the subagent permission is named "subagent". Not checked with a running OpenCode; verify without driving it interactively.
- **OpenCode roles on Windows + WSL.** Not run there.
- **OpenCode role tabs after an Orca restart.** The kit wakes asleep Claude and Codex tabs only; an OpenCode role's tab after a restart is not verified (its session is kept by `--session`).
- **Asleep tabs on Linux.** Whether Orca keeps tabs asleep after a restart there, and whether the internal call can be reached, is unverified; `roles` treats them as closed and opens new tabs. On Orca for Windows with WSL terminals the kit wakes them (R1 of the live checks).

## Revert when Orca fixes it

- **Agent name in tab titles and `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`.** A workaround for stablyai/orca#32090: Orca 1.4.239 does not recognize a native Claude Code by its process. When an Orca release includes stablyai/orca#32999, remove the `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` export from `bin/agent.sh` so Claude's session titles come back, decide whether the title suffix (`tab_title_of` in `bin/lib.sh`) stays, check stablyai/orca#22655, and update the README paragraph in "Using other agents" and the troubleshooting row.
- **OpenCode dispatch through `dispatch --inject`.** `orca orchestration worker-start --terminal` never sees an `opencode mini` tab as ready (its `agent_readiness` stage timed out with Orca 1.4.218), so the Planner is told to dispatch OpenCode workers with `--inject`. When Orca recognizes the tab, drop that sentence from the Planner's message (bin/lib.sh planner_msg) and the README note.
- **Retrying `opencode models` while OpenCode's service warms up** (`oc_model_state` in bin/kickoff.sh): the first call after a start can fail; remove the retry when OpenCode answers at once.
- **trust "never" waits on Orca's `agentIdentity`** (kickoff.sh `agent_trusted`): Orca's screen text does not reliably show Claude Code's trust dialog; go back to the screen when it does.
- **Waking asleep tabs through Orca's internal `terminal.reveal`.** After a restart Orca keeps agent tabs asleep and has no CLI command to list, wake or close them, so `bin/wake-tab.cjs` calls the app's internal runtime client (macOS and Orca for Windows with WSL terminals). When Orca adds a command for it, use that command in `wake_tab` (`bin/lib.sh`), remove `bin/wake-tab.cjs` and the platform limits in the README.

