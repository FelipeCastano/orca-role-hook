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

## Pending verification

- **Codex and OpenCode tab titles.** The kit titles each role's tab with the agent's name ("Researcher (codex)") so Orca recognizes it as an agent (stablyai/orca#32090). Claude Code is kept from retitling its tab with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`; whether Codex and OpenCode retitle their tab, and with what switch to stop it, is unverified (for Codex, `[tui] terminal_title` in `~/.codex/config.toml`, see stablyai/orca#26557). Verify without driving the agents interactively.
- **The tab-title fix on Windows + WSL.** Verified on macOS only, including a simulated Ubuntu `.bashrc` that retitles the tab at its prompt (the kit sets its title again before starting the agent). Confirm on WSL that `worker-start --terminal <role>` is accepted after `roles`.
- **WSL: stale handles after an Orca restart.** On WSL, `orca-roles.env` kept old handles for every role but one after Orca restarted, and the "Roles reopened" message carried them. Not reproduced on macOS. A side effect seen there: `relaunch-role.sh` reopened the whole team, because the other roles' tabs counted as "closed but Orca kept its session running".
- **Asleep tabs on Linux.** Whether Orca keeps tabs asleep after a restart there, and whether the internal call can be reached, is unverified; `roles` treats them as closed and opens new tabs. On Orca for Windows with WSL terminals the kit wakes them (R1 of the live checks).

## Revert when Orca fixes it

- **Agent name in tab titles and `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`.** A workaround for stablyai/orca#32090: Orca 1.4.239 does not recognize a native Claude Code by its process. When an Orca release includes stablyai/orca#32999, remove the `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` export from `bin/agent.sh` so Claude's session titles come back, decide whether the title suffix (`tab_title_of` in `bin/lib.sh`) stays, check stablyai/orca#22655, and update the README paragraph in "Using other agents" and the troubleshooting row.
- **Waking asleep tabs through Orca's internal `terminal.reveal`.** After a restart Orca keeps agent tabs asleep and has no CLI command to list, wake or close them, so `bin/wake-tab.cjs` calls the app's internal runtime client (macOS and Orca for Windows with WSL terminals). When Orca adds a command for it, use that command in `wake_tab` (`bin/lib.sh`), remove `bin/wake-tab.cjs` and the platform limits in the README.
