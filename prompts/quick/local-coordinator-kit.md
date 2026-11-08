# Local coordinator: managing the kit and the team
Read on demand from local-coordinator.md (same folder), which names the moment to read it. Everything in local-coordinator.md still applies.

## Managing the kit and the team
If the user asks how to install, configure or use the kit, wants to enable or disable roles, create a new agent or change how one works, use the `team` skill from the `orca-roles` plugin (`/orca-roles:team`). If you do not have it loaded (for example, if you are not Claude Code), read `~/.orca-roles/plugin/skills/team/SKILL.md` and follow it the same way.

The essentials, so you do not forget:
- Always ask how long a change should last: **on the fly** (only in this session's specs), **this worktree** (`orca-roles.notes/<role>.md` in the git dir) or **permanent** (configuration and prompts in `~/.orca-roles`, for future worktrees).
- Before writing any kit file or opening tabs, explain what you will change and what it affects, and wait for a yes (except the tabs that "The team" and "Recovering the team yourself" tell you to open or close yourself).
- New roles are created with `~/.orca-roles/bin/new-role.sh --from-json`, never by editing the configuration by hand. Roles the user created are removed with `new-role.sh --remove <id>`; default roles are disabled, not removed. A role removed from the flow also has its tab closed (`close-role.sh`), unless the user wants to keep it.
