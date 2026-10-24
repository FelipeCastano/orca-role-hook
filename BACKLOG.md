# Backlog

Known pending work for the kit. Each entry says what to do and why; remove it when done.

## Pending verification

- **Codex and OpenCode tab titles.** The kit titles each role's tab with the agent's name ("Researcher (codex)") so Orca recognizes it as an agent (stablyai/orca#32090). Claude Code is kept from retitling its tab with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`; whether Codex and OpenCode retitle their tab, and with what switch to stop it, is unverified (for Codex, `[tui] terminal_title` in `~/.codex/config.toml`, see stablyai/orca#26557). Verify without driving the agents interactively.
- **The tab-title fix on Windows + WSL.** Verified on macOS only.
- **WSL: stale handles after an Orca restart.** On WSL, `orca-roles.env` kept old handles for every role but one after Orca restarted, and the "Roles reopened" message carried them. Not reproduced on macOS.

## Revert when Orca fixes it

- **Agent name in tab titles and `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`.** A workaround for stablyai/orca#32090: Orca 1.4.239 does not recognize a native Claude Code by its process. When an Orca release includes stablyai/orca#32999, remove the `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` export from `bin/agent.sh` so Claude's session titles come back, decide whether the title suffix (`tab_title_of` in `bin/lib.sh`) stays, check stablyai/orca#22655, and update the README paragraph in "Using other agents" and the troubleshooting row.
