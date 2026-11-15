# Local coordinator: rounds
Read on demand from local-coordinator.md (same folder), which names the moment to read it. Everything in local-coordinator.md still applies.

## Ids
Each experiment has its own checkpoint and handoff id, `exp<n>`. n is fixed when the experiment's first Dev task is dispatched: one more than the highest `exp` id already in the ledger (1 for the first), recorded in the ledger as `- <UTC time> exp<n> = <experiment name> (experimentation/specs/<experiment>.md)`. The id never changes after that, even when PLAN.md is reordered or an experiment is inserted: read the ledger, not PLAN.md, to find an experiment's id. The Dev fix and Tester rounds of Review round k use the id `review<k>`.

## Paths, not content
- Dev's "Implement and run" or "Fix" task: the path of the experiment's spec (`experimentation/specs/<experiment>.md`), the base ref and the brief's limits. Never name tests or test commands for Dev: Dev runs none.
- Before each Dev "Implement and run" task, run `~/.orca-roles/bin/oracle.sh --lint <spec path>` from the worktree: exit 0, dispatch; exit 1, do not: send the Researcher a Fix task with the lint's output copied in full, lint the spec it returns, and if it fails again tell the user and wait; exit 2, tell the user in one line and do not dispatch; exit 3, tell the user in one line and dispatch without the lint.
- Reports: each worker writes its full report to a file (`<its scratchDir>/reports/<task_id>.md`, its `--report-path`) and its `worker_done` body names it. Open a report file only when you act on it: a finding, a question, a Dev decision the spec should have settled, or a `decide` or `close` task. Pass report paths, not their text, to the next role, except findings, which are still copied in full into fix and decide tasks.

## The routine handoff
After Dev's `worker_done` on an experiment, when there is nothing in it to act on (no question, no decision to route, no Data review pending), run from the worktree `~/.orca-roles/bin/handoff.sh exp<n> --to <tester handle> --run <run_id> --spec <absolute spec path> --report <Dev's report path>`, adding `--note "<text>"` for state the report does not hold. Exit 0: the round is dispatched. Any other exit: nothing was dispatched, tell the user in one line and brief the round by hand as "Briefed rounds" says. After each Tester `worker_done`, record `~/.orca-roles/bin/checkpoint.sh <id> <n>` (n = one more than the id's last checkpoint) and append to the ledger `- <UTC time> <id> Tester round <k>: <verdict>; report <path>; checkpoint <ref>`.

## Fixes
All open findings of a round go to Dev in one fix task (the path of the report that holds them and the findings routed to Dev, copied in full), then one Tester round.

## Briefed rounds
Every Tester task that `handoff.sh` does not write (a fix round where you acted on the report, a Review-stage round, the stage's full-suite task) carries *the task* (the spec path) and *the state* (the files changed, Dev's report path, `git diff <previous checkpoint ref> <latest ref>`, the id's base ref as a line written exactly `Base ref (for the base check): <ref>` (the label `handoff.sh` writes, which the Tester reads), and from the second round on what earlier rounds verified and the findings still open, as ledger lines and report paths). The full-suite task says it is the stage's full run. The brief passes information only: it never tells the Tester what to test, mutate or look at.
