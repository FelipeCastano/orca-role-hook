# Local coordinator: resuming, coming back and after a clear
Read on demand from local-coordinator.md (same folder), which names the moment to read it. Everything in local-coordinator.md still applies.

## Resuming a workspace after a restart
If your startup message says the workspace is being RESUMED, the team's previous tabs died (restart, Orca closed) and your conversation memory was lost, but the state lives in Orca and in your scratch folder. Recover it like this, before talking to the user and without assigning anything yet:

1. **Normal startup** (steps 1 to 3 of the previous section).
2. **Run.** `orca orchestration run-list --json` and find this worktree's Run: its objective mentions the paper or the project. Bind to it with `orca orchestration run-use --id <run_id> --json`. If there is none, there was no orchestrated work: tell the user and start from the phase in your startup message.
3. **Tasks.** `orca orchestration task-list --run <run_id> --json`: what is completed, in progress, blocked or pending. The full specs of the in-progress tasks tell you which phase and stage you were on.
4. **Communications.** `orca orchestration inbox --limit 50 --full --json`: read the latest `worker_done` (findings, verdicts), the unanswered `question` messages and the `escalation` messages. If you need more history, raise `--limit`. It also reads with `orca orchestration check --json` and acknowledges each batch with `check --ack <delivery_id> --json` until `count` is 0: a batch left unacknowledged is still open and blocks the notices (after a restart, `run-use` fences it and its messages come back in the next batch).
5. **Orphan dispatches.** `orca orchestration worker-list --run <run_id> --json`. Dispatches whose terminal is none of your new handles point to dead tabs: close them with `orca orchestration worker-abandon --dispatch <dispatch_id> --json`. Their task is left to reassign.
6. **State.** Read your ledger and `changes-log.md` in your scratchDir, STATE.md if it exists, and `git status --short`, `git diff --stat`, `git log --oneline -15`. Compare them with the `worker_done` messages: note files a report mentions that are not there, or changes no report mentions.
7. **Summary for the user**, in this order: the Run's objective; the phase; stages closed, in progress and pending; each worker's last message; unanswered questions; commits and uncommitted changes; and what you propose to do now. Wait for their confirmation before reassigning anything.
8. **Resume.** When the user confirms, reassign the in-flight tasks with the common mechanics, stating in the brief that it is a retry after a restart and what had already been done (`--retry-of <dispatch_id>` if Orca accepts it).

## Coming back with your memory
If your startup message says you are BACK with your previous conversation, Orca restored the team's tabs after a restart and the kit reopened each role with its own conversation, so you remember the paper and the decisions. What changed is the plumbing: every handle is new (the list in your startup message), the dispatches that were in flight point to terminals that no longer exist, and each worker only remembers its own conversation. Before talking to the user:

1. Bind to the Run again: `orca orchestration run-use --id <run_id> --json`.
2. Read your messages: `orca orchestration check --json`, acknowledging each batch with `check --ack <delivery_id> --json` until `count` is 0 (if an `--ack` fails with `consumer_fenced`, that batch is from before the restart: run `check --json` again and its messages come back in a new batch), then `inbox` if you need history. Read also the workers' one-line replies: they say whether they had a task in progress.
3. `orca orchestration worker-list --run <run_id> --json`: abandon the dispatches that point to old handles (`worker-abandon --dispatch <dispatch_id> --json`). Their tasks stay to re-dispatch.
4. `git status --short` and `git log --oneline -5`: confirm the repository is where you remember.
5. Tell the user, in a few lines: where you were (phase and stage), what was interrupted and what you propose to re-dispatch. Wait for their confirmation (not when your startup message says you were reopened by your own launch.sh --reopen: then re-dispatch at once as in step (4) of "Recovering the team yourself" and tell the user in one line); then send each interrupted task to the same role's new handle, saying in the brief that it is a retry after a restart and that the worker already did part of it (it remembers).

If something does not match your memory (a report you never saw), say so instead of guessing.

## After your conversation was cleared
If your startup message says your conversation was cleared, you lost your memory but nothing else stopped: the workers' tabs are alive, the handles in the message are current and the dispatches in flight are still valid. Recover the state before talking to the user, without assigning or abandoning anything:

1. Steps 1 to 4 and 6 of "Resuming a workspace after a restart" (startup, Run, tasks, communications, state). Skip step 5: no dispatch is orphaned.
2. A worker (the Planner included) with a task in flight keeps working on it: wait for its `worker_done` as usual. Re-read the ledger and `changes-log.md` (see "Changes outside the plan"): they are your memory.
3. Tell the user, in a few lines: the Run's objective, where the paper is (phase and stage), what is in flight, the unanswered questions and what you propose to do next. Wait for their confirmation before dispatching anything new.
