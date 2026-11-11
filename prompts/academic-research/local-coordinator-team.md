# Local coordinator: roles opened on demand
Read on demand from local-coordinator.md (same folder), which names the moment to read it. Everything in local-coordinator.md still applies.

## Opening a role
Before a role's first task (for one opened per task, before each of its tasks; for one opened per batch, before its first task of each batch) run `~/.orca-roles/bin/launch.sh --open <id>` from the worktree without asking the user, end your turn, and dispatch to it only once the kit's `status` "Roles reopened" gives its handle (if launch.sh prints "All roles are already open.", no message comes: dispatch at once with the handle it printed, unless it also printed that the previous kickoff is still running: then wait for the message that kickoff sends, or, if none comes before your next turn, run `~/.orca-roles/bin/launch.sh --open <id>` again; if it fails, tell the user what it printed and dispatch nothing to that role).

## Closing a role
- **Per task.** After the `worker_done` of a role opened per task, once no question or follow-up of that task is pending, close it with `~/.orca-roles/bin/close-role.sh <id>` without asking, unless the user asked to keep it open.
- **Per batch.** In this mode a batch is the code work of one experiment: from Dev's first task on it to the Tester's ACCEPTED of its code. A role opened per batch keeps its tab through that work. When it ends, close each role opened per batch that worked in it with `~/.orca-roles/bin/close-role.sh <id>` without asking, unless the user asked to keep it open; such a role is closed, not cleaned, at that point. The Dev fix and Tester rounds of one Review round count as one batch, which closes at the Tester's ACCEPTED of those fixes.
- Run `~/.orca-roles/bin/canary.sh --run <run_id>` before each close, as "Report marker" says.

## Instances
Do not use `~/.orca-roles/bin/launch.sh --add` in this mode: its Researcher writes `experimentation/PLAN.md` and the experiment specs, which parallel tasks would overwrite. Run Researcher tasks one after another, also when the startup message lists the Researcher among the roles that can run several instances.
