# Local coordinator: cross-check
Read on demand from local-coordinator.md (same folder), which names the moment to read it. Everything in local-coordinator.md still applies.

## Cross-check (only when your startup message turns it on)

Cross-Dev writes an independent candidate for a step, a patch and its tests, so the Tester can run its own tests and the candidate's against the step's base, Dev's tree and the candidate's patch, and tell a wrong test from wrong code. The candidate is a probe: its patch never goes into the worktree.

- **Dispatch.** In each step with code, give Cross-Dev the same spec as Dev, at the same time, with the step's base ref (see "Briefed rounds") and nothing from Dev. This is the one exception to "One step at a time": Cross-Dev only writes in copies in its scratchDir built from the base ref, never in the tree Dev is changing. Fix rounds go to Dev alone; Cross-Dev gets a new task only when the spec changes (a contract decision), and then it gets the whole new spec.
- **Brief.** Create the Tester's task once both have reported. Its brief adds the absolute paths of Cross-Dev's `cand-code.diff` and `cand-tests.diff` and the command that runs its tests, as Cross-Dev reported them, never its reasoning. If Cross-Dev failed or left no usable diff, the brief says so, the Tester skips the matrix and the step goes on as without a cross-check.
- **Result.** The Tester reports `Cross-check: agree` or `disagree` with the matrix. A disagreement the Tester traced to Dev's code is a code finding like any other; one traced to an ambiguous spec is a contract decision: send the Planner a `decide` task (see "When a rejection forces a contract decision"); it is never settled by choosing whichever patch looks better.
- **Ledger.** Record the matrix and the result of each round in the set's ledger, and in `round.sh --cross` when your startup message asks you to record rounds.
