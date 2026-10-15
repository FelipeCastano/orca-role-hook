# orca-roles

Kit for [Orca](https://github.com/stablyai/orca) that automatically opens a team of agents with defined roles in every new worktree and coordinates them through **Orca Orchestration**. You only talk to the Planner; the rest of the team gets all its work from it.

The everyday configuration (which roles are enabled, with which model, agent, MCP and parameters) lives in `~/.orca-roles/config.json`. A project's exceptions go in its `.orca-roles.json` or in the setup script options. See [Configuration](#configuration).

## Start here: get Claude's help with the setup

The kit ships a Claude Code plugin with a guide to everything below (installing, registering projects, configuring the team, creating agents and troubleshooting). Install it first, so you can ask Claude at any step. In Claude Code, run:

```
/plugin marketplace add FelipeCastano/orca-role-hook
/plugin install orca-roles@orca-role-hook
```

Choose the user scope when asked, and run `/reload-plugins` if the install says so. Then just ask, for example: "help me install orca-roles", or invoke the guide with `/orca-roles:team`.

- The marketplace is read from the repo's default branch (`main`). If `/plugin marketplace add` says `Marketplace file not found`, your `main` does not have it yet; add it from a local clone instead: `/plugin marketplace add ~/orca-role-hook`.
- Without the marketplace: clone the repo and start Claude Code with `claude --plugin-dir orca-role-hook/plugin`.
- Once the kit is installed, its Planner loads this same guide by itself; the plugin is only needed to get help outside the kit's sessions.

If you prefer to do it by hand, everything is explained below.

## Quick start

1. **Install the kit** in a terminal (on Windows, inside WSL; see [Windows with WSL2](#windows-with-wsl2)). You need `jq`, Claude Code and Orca with Orchestration enabled.
   ```bash
   git clone git@github.com:FelipeCastano/orca-role-hook.git && bash orca-role-hook/install.sh
   ```
2. **Register the kit in your project**, once: in Orca, **Settings → Repository → *your project* → Setup script**, paste `$HOME/.orca-roles/bin/launch.sh`; or run `roles-yaml` in a terminal in the project. See [Setting up a project](#setting-up-a-project-once-per-project).
3. **Create a worktree** from the project's **"+"**. The team's tabs open and the Planner starts planning with you.
4. **Tune the team** depending on the scope:
   - For good: `enabled`, `model`... in `~/.orca-roles/config.json` ([Configuration](#configuration)).
   - One project only, without files: options on the setup script line, e.g. `$HOME/.orca-roles/bin/launch.sh --disable e2e-tester,deployer` ([Exceptions in the setup script](#exceptions-in-the-setup-script)).
   - One project only, versioned: `.orca-roles.json` at the repo root ([Per-project configuration](#per-project-configuration)).
5. **Ask the Planner.** It knows the kit thanks to its skill: "create an agent that reviews security", "disable the E2E-Tester in this project", "make Dev use pnpm in this worktree only", "how do I update the kit?". See [The Planner's skill](#the-planners-skill).
6. **After a restart**, or in a worktree where the hook did not run, launch `roles` in a workspace terminal ([Resuming after a restart](#resuming-after-a-restart)).

## Roles

By default:

| Tab | Model | MCP | Role |
|---|---|---|---|
| **Planner** | Opus 5.5 | All of yours (incl. Jira) | The only agent that talks to you. Plans in steps, audits its plan with its plan review method before presenting it (and has the Auditor audit it too when it is very complex: more than about 5 steps, a change to a contract or persistent data, anything touching security, permissions, credentials or leaving the worktree, or an ambiguous request resolved by its own interpretations; otherwise it says it judged it safe to go without), hands out the work, supervises and reports to you. Replies in your language (or the one in `settings.language`). |
| **Researcher** | Opus 5.5 | context7 | PoCs, metrics, performance, load and capacity. Works in `research/`. |
| **Dev** | Sonnet 5.5 | context7 | Implements the production code. |
| **Tester** | Sonnet 5.5 | None | Does not review: implements and runs the tests, covering each criterion as a family of inputs with its boundaries, checks them with a few mutants of its own, within limits on quantity, parallelism and time, and cleans up at the end. A change that only touches prompt, README or skill text gets no text checks and no text mutants: it runs the safety-rule checks (`tests/smoke.sh rules`) and reads the diff for weakened rules, and the rest of its review still applies. |
| **Auditor** | Opus 5.5 | None | Reviews Dev's code and the Tester's tests with its code review method (including mutation, in place in the worktree with a backup and a verified restore). It audits once per set of steps, not per step. It also audits the Planner's plan, read-only, when the Planner judges it very complex. Like the Tester, it runs no text mutants on prompt-only changes. Only findings from the rejection threshold up (default `high`) reject; the rest are notes. Defaults: `maxMutants` 8 (Tester `maxSelfMutants` 3). Existing installs that still had the old defaults (15 and 5) move to the new ones on update; values you set yourself are kept (except exactly 15 and 5 themselves, which every update moves to the new defaults; to keep them, set them in the project's `.orca-roles.json`). |
| **E2E-Tester** | Opus 5.5 | Playwright | Proposes an E2E test plan for the application (front end or API) and, once you approve it, runs it in a headless browser with your session, with screenshots at the key points. |
| **Deployer** | Sonnet 5.5 | None | Starts and stops the application locally (API, front end and required services) when asked, and maintains `DEPLOYMENT.md` with the step-by-step guide for dev and prod. Never deploys. |

They all start in **auto mode**. The workers know that all their work comes from the Planner and share common rules (`prompts/programmer/common-workers.md`): do not create worktrees or terminals, do not touch git outside their worktree, do not push and clean up whatever they start.

This is the programmer team; see [pr-reviewer mode](#pr-reviewer-mode) and [academic-writer mode](#academic-writer-mode) for the other teams.

### Prompt structure

Every role prompt follows the same pattern, in this order:

1. `# Role: NAME` and the mission in one or two sentences.
2. `## When you receive a task`: numbered steps (if the role has several kinds of task, one subsection per kind).
3. `## Limits`: what it must not do.
4. `## Parameters`: the ones it receives from `config.json` and their default value (or "None").
5. `## ... method` (only when the role applies one: the Auditor and the Planner).
6. `## Report`: exact format of the `worker_done`.
7. Closing line: "Now reply only "X ready" and wait for tasks."

The Planner is the partial exception: it is not a worker, so its sections are Startup, Team, Phase 1, Mechanics, Phase 2, Limits, Parameters, Plan review method and Report to the user. The review methods live inside the prompt of the role that applies them, not in separate files: the Auditor and the Planner reread their own prompt before each review.

## Flow of each step

1. **Researcher** investigates if something needs deciding first.
2. **Dev** implements.
3. **Tester** implements and runs the tests. If they fail because of the code, Dev fixes it.
4. The **Auditor** does not take part in each step (see "Set audit" below). If the Tester rejects the step, its findings go to Dev or the Tester as appropriate, and it repeats until it accepts (after 3 rejected rounds, the Planner checks with you).
5. If an E2E test is needed: **Deployer** starts the application → **E2E-Tester** proposes a plan → you approve it → **E2E-Tester** runs it → **Deployer** stops it.
6. **Researcher** validates performance or capacity if needed.
7. **Deployer** updates `DEPLOYMENT.md`.
8. The **Planner** closes the step only with the Tester's ACCEPTED (and the E2E-Tester's and the Researcher's if they took part) and its closing checkpoint recorded (no commit per step), reports it to you (result, changes, news, decisions) and only then opens the next one, on top of the uncommitted tree.

Steps are atomic and strictly sequential: one behavior, one step in flight at a time. The steps that go into one PR form a set, committed at its close, once the set is complete and audited, in logical commits (each easy to understand on its own) that you approve as a list. Nobody commits per step, and each commit message describes what it delivers and why, not the pipeline. A long ticket becomes a chain of small steps, and the Planner proposes one Jira subtask per step, created once you approve the plan and say yes to creating them. Commits and PRs match the format of the repo's recent history, and Jira texts that of the Jira project's recent ones; the Planner re-reads them every time. The next step does not start until the current one has its ACCEPTED(s) and its closing checkpoint. Nothing leaves the worktree without your explicit yes to that action: the set's commits, pushes, pull requests and every Jira write are shown to you first, and the workers never touch Jira or GitHub. Dev gets one precise task per step and never the next one until the current step has gone through Dev and the Tester and is closed.

**Set audit.** Each step goes Dev → Tester and closes with a checkpoint; nothing is committed meanwhile. The Auditor audits once per set, when the last step of the set (everything that goes into one PR) is closed, over the whole uncommitted set (the diff from the branch base to the working tree, recorded first as `checkpoint.sh set 1`), and runs the full test suite once as its baseline. Findings at or above medium are fixed in the working tree (Dev for code, the Tester for tests), recorded as `checkpoint.sh set <n+1>` and re-audited with a corrections-only review (just the diff between the two set checkpoints and the findings they answer, running only the affected sections); findings below medium (low and notes) are fixed without a new audit, or left as notes if you agree. Only then is the set committed, split into logical commits built from the reviewed tree (the Tester's and the Auditor's corrections go into the commit they belong to), on your explicit yes to the list of commits (subject, files and full message of each) after the convention check; the messages describe what each commit delivers and why, because commits describe functionality, not history. The Planner has one full local run done before proposing the push unless the audit's baseline already ran on the final tree (CI runs the full suite on the PR); push and PR each need their own yes. Nothing is ever fixed up, autosquashed, rebased, amended or force-pushed: a finding after the set's commits (for example CI failing on the PR) is fixed with a normal commit on top, on your yes. After the last commit the Planner clears the checkpoints (`checkpoint.sh --clear-all`).

The Planner does not block while the workers run: it hands out the tasks, tells you what is running and stays free, so you can keep refining the plan with it. Orca notifies it when a worker reports, and you can ask it for the status at any time. Workers send no heartbeats: they only report when they finish, ask when blocked or escalate when something fails, so the Planner is not woken (and you are not interrupted) by "still alive" messages. It detects a stuck worker by the time its terminal last printed anything.

**Briefed rounds.** After every Dev or Tester report the Planner records the tree with `checkpoint.sh <step> <n>` and creates the next worker's task with a brief: the task (goal, criteria, threat model) and the state (files changed, what Dev and the Tester did and found, what earlier rounds already verified, the findings still open). The first brief carries the whole step's diff (from the previous step's last checkpoint, or from HEAD for the first step of the set) and later ones only what changed since that role last looked (`git diff <earlier checkpoint> <latest checkpoint>`), so the Tester does not rebuild the step from zero in every round; the brief is information, never instructions on what to test, and they still verify the code themselves. The Planner keeps a ledger per step (`ledger-<step>.md` in its scratch folder) as the source of every brief and clears all the checkpoints after the set's last commit.

If a role is disabled in the configuration, the Planner skips its part of the flow and tells you when a step would have needed it.

## Installation

Clone the repo and run the installer from the clone:

```bash
git clone git@github.com:FelipeCastano/orca-role-hook.git && bash orca-role-hook/install.sh
```

It installs into `~/.orca-roles/`, creates your `~/.orca-roles/config.json`, adds the `roles`, `new-role` and `roles-yaml` commands to your shell and explains how to register the kit in your projects. **To update**, pull the changes and run the installer again: your configuration is kept (values and order of your roles) and only the new options are added. A `visual-tester` role from older versions becomes `e2e-tester` with its settings. Update the kit with no team open, or clean the open teams' context afterwards (see [Cleaning the workers' context](#cleaning-the-workers-context)), because running agents keep the old prompt paths.

```bash
git -C orca-role-hook pull && bash orca-role-hook/install.sh
```

It can also be installed without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/FelipeCastano/orca-role-hook/main/install.sh | bash
```

The installer takes no options: roles are enabled and disabled with `enabled` in `config.json` (see [Configuration](#configuration)).

The first time the E2E-Tester uses the browser, `npx playwright install chromium` may be needed.

## Setting up a project (once per project)

**Add Project → Browse folder**, picking the repo root (the folder with `.git`), not a worktree. Then register the kit as the project's setup script in one of these two ways. Orca's CLI has no command for setup scripts, so the installer cannot do it for you.

**a) In Settings.** **Settings → Repository → *your project* → Setup script**:
```
$HOME/.orca-roles/bin/launch.sh
npm install
```
The second line is optional. Keep `launch.sh` first and **Run setup command** on.

**b) With `roles-yaml`.** In a terminal inside the project (in any worktree or in the main checkout):
```bash
roles-yaml            # to undo it: roles-yaml --remove
```
It creates an `orca.yaml` with the setup script at the main checkout's root and lists it in `.worktreeinclude`. Both stay ignored in `.git/info/exclude`, the local equivalent of `.gitignore`: the project's `.gitignore` is not touched, there is nothing to commit and your teammates see nothing. It works because Orca copies the ignored files listed in `.worktreeinclude` to every new worktree, before looking for its setup script. It only affects the worktrees you create from now on.

- If the project already has a committed `orca.yaml` or `.worktreeinclude`, `roles-yaml` does not modify them: it tells you which line to add. Use option a) if you do not want to touch them.
- Orca decides which setup scripts run with the project's **setup source** (Settings → Repository → *your project*), which has three values:
  - **local-only:** only the script in Settings runs; `orca.yaml` is ignored. This is also the case when the project has a script in Settings and no source was ever chosen (implicit local-only: with no source chosen, any script in the local box makes it local-only).
  - **run-both:** `orca.yaml` runs first, then the script in Settings.
  - **shared-only:** only `orca.yaml` runs.
- `roles-yaml` checks this through the Orca CLI before writing anything. With local-only and no `launch.sh` in the local script it stops without writing and tells you the two fixes: put `$HOME/.orca-roles/bin/launch.sh` as the first line of the local script, or switch the source to "run both". If the local script already runs `launch.sh` it tells you `roles-yaml` is not needed (with "run both" it would run twice). It also warns if the setup policy is not "run by default" (with "ask", `orca worktree create` needs `--setup run`). If Orca cannot be queried (not running, project not registered, no CLI) it says so and writes `orca.yaml` anyway.
- `roles` repeats this check every time it runs and warns if new worktrees would not start the kit (or would start it twice); `roles-yaml --check` runs only the check.
- To check it yourself: `orca repo show --repo path:<main checkout root> --json | jq .result.repo.hookSettings` (`commandSourcePolicy`, `setupRunPolicy` and `scripts.setup`).
- Changes to `orca.yaml` (for example, adding `npm install`) are made in the main checkout's one; each new worktree gets a copy.

## Usage

Create a worktree from the project's **"+"**. In a few seconds you will have your roles' tabs and the Planner will start planning with you.

- **From a Jira ticket:** the kit reads the ticket Orca links to the worktree (`linkedWorkItem` in `orca worktree show`) and passes it to the Planner, which reads it and plans from there. If the worktree is not linked, it tries the branch, but only when the uppercase key starts the branch or one of its segments (`DEVGD-220-new-api`, `feature/DEVGD-220`), so `fix-123` or `release-1.4` are not taken for tickets. The session Orca creates by default with the ticket's name is interrupted and closes by itself.
- **Where the hook does not run** (main checkout, folder projects, existing worktrees): run `roles` in a workspace terminal. It does not duplicate open tabs.

### Connecting Jira

The Planner reads tickets with the Atlassian MCP. By default it uses your own Claude Code connectors (`"mcp": "all"`), so connect Atlassian once in Claude Code: run `/mcp`, pick the Atlassian server and authenticate. If you do not have it yet, add it with `claude mcp add --transport sse atlassian https://mcp.atlassian.com/v1/sse` and then authenticate it with `/mcp`.

If the Planner says it has no Jira tool, its session is not authenticated: run `/mcp` in the Planner's tab, authenticate Atlassian and tell it to continue, or paste the ticket into the conversation.

## E2E testing: browser, session and screenshots

The E2E-Tester does not use Orca's embedded browser: it controls its own Chromium through the Playwright MCP. Screenshots are requested over the protocol, they are not screen captures, so they work even if the window is behind others or does not exist. By default the browser is **headless**: you can keep working while it tests.

**Session.** If your application requires a login (Entra, Google, MFA...), sign in yourself once:

```bash
~/.orca-roles/bin/browser-login.sh https://localhost:5173
```

It opens a visible browser, you wait for the application to load with your session, you close the window and the session (cookies and localStorage) is saved in `~/.orca-roles/browser/<project>.json`. The E2E-Tester starts with it in isolated mode: nothing is written to disk during the test and several worktrees can test at the same time. If the application asks it to log in, the E2E-Tester does not try to authenticate: it tells the Planner, which will ask you to run the command and will launch the task again. The first time, `npx playwright install chromium` may be needed.

It depends on your application keeping the session in cookies or `localStorage`; if it keeps it in `sessionStorage`, it does not survive. Tokens expire according to your identity provider: when the E2E-Tester sees the login screen again, run the command again.

**Screenshots.** They go to `<evidenceDir>/step-<N>/` in the worktree (by default `qa-evidence/`, locally ignored by git) thanks to `--output-dir`. **Network.** To validate payloads, the E2E-Tester injects a hook on XHR/fetch with `browser_evaluate` and reads the bodies from the page; it never logs headers.

**Regression.** This is exploratory validation. The E2E-Tester reports the exact sequence of steps it ran so that, if a flow deserves to be repeated, the Planner hands it to the Tester as a Playwright test.

All of this is configured in the `playwright` server of `mcpServers`; see [placeholders](#placeholders-in-mcpservers) to remove `--headless` or change paths.

## Cleaning the workers' context

Each worker accumulates everything it has done in its conversation. When a step closes that context is no longer useful (each new task comes with its full spec) and a long context makes responses more expensive and worse. Cleaning it opens a new conversation in the agent (`/clear` in Claude Code) and resends its role and parameters, so the worker is "ready" again as at startup.

- **When closing each step**, the Planner proposes it together with the report (if `cleanWorkersAfterStep` is on).
- **When you ask**, for the workers you say or for all of them.

In both cases the Planner first explains what it will do and what is lost, excludes the workers with a task in flight and waits for your confirmation. If you tell it to always do it without asking, it remembers that for the session. It never cleans itself: its context is the memory of the plan.

Under the hood it runs `~/.orca-roles/bin/clean.sh <role> [...]` (or `--all`), which you can also run yourself from a worktree terminal. It accepts the role id, the tab title or the handle.

If you clear a role's conversation yourself (`/clear` in Claude Code, `/new` in Codex), the Planner's included, its role message is gone with the rest of the conversation. Each role gets one line outside the conversation, which clearing it keeps, telling it to ask for that message again: on your next message it runs `~/.orca-roles/bin/clean.sh --msg <role>` and follows what it prints. The Planner gets the current handles and a "cleared" mode: it recovers the Run, the tasks, the latest communications and the state of the code, leaves the work in flight running, and gives you a summary before dispatching anything.

- `claude`: the line goes in its system prompt (`--append-system-prompt`).
- `codex`: as `-c developer_instructions=...`. It replaces any `developer_instructions` of your `~/.codex/config.toml` for these roles; put yours in the role's `extraArgs` if you need both.
- `custom`: the kit cannot know how the agent takes instructions, so the line is the `{anchor}` placeholder and `$ORCA_ROLES_ANCHOR`: pass it with the agent's system prompt flag, if it has one, in `command`. Without it, after clearing the agent by hand use `clean.sh <role>` or tell it to run `clean.sh --msg <role>`.

## Resuming after a restart

If you shut down the computer or close Orca, the roles' tabs die, but the state does not: Orca Orchestration's tasks, messages and Runs persist, and the code is in the worktree. What is lost is each agent's conversation memory.

To resume, run `roles` in a workspace terminal (the hook does not fire in existing worktrees). What happens depends on what Orca kept:

- **Orca restored the tabs** (it does so when you reopen it after a restart, relaunching each Claude session with `--resume` but without the kit's settings: no auto mode, no plugin, no per-role MCP, default model). The kit recognizes each restored tab by its terminal identity (`orca-roles.pty` in the worktree's git dir; the handles change, the identity does not), reads the Claude session Orca resumed in it, closes it and reopens the role with that same session plus the kit's settings. Every role comes back **with its memory**: the Planner remembers the plan and the decisions, and each worker what it was doing. The Planner then rebinds the Run, abandons the dispatches that pointed to the old terminals, tells you where it was and what was interrupted, and re-dispatches only when you confirm. This needs the native Claude Code installer: the kit reads the resumed session from the `--resume` argument of the `claude` process, and an npm install runs under `node` and renames its process to `claude`, which overwrites those arguments, so the roles reopen without memory (everything else still works).
- **The tabs are gone** (closed before the restart, or a session Orca could not resume): the kit opens new tabs and starts the Planner in **resume mode**: before talking to you, it recovers the Run with `run-use`, reads the task list and the team's latest communications, closes the dispatches that pointed to dead tabs, reviews `git status`, `git diff` and the log, and gives you a summary: what was closed, what was in progress, which questions were left unanswered and what it proposes to do. The workers come back clean; they do not need memory because each task comes with its full spec (the same principle as [context cleanup](#cleaning-the-workers-context)). The Deployer detects that the previous API died and starts it again if asked.

If Orca cannot say whether the saved tabs are still open (its window is not ready, or `orca terminal list` keeps failing), `roles` stops with "Orca is not ready (<code>)" before closing or opening anything, and leaves the saved team as it was: run `roles` again once Orca is ready. Only one `roles` runs per worktree at a time (`orca-roles.lock` in its git dir): a second one waits up to 60 seconds for the first, and takes over a lock whose process is gone.

When `roles` opens or reopens workers but the Planner keeps its tab (for example the window was lost, or a worker's agent died), the Planner would keep the old handles and `worker-start` would fail with `terminal_handle_stale`. So the kickoff sends it a `status` message "Role handles changed" listing the roles that were opened and the current handle of every role. The Planner uses those handles from then on, abandons the dispatches that pointed to other terminals and re-dispatches their tasks to the new handles. No message is sent when only the Planner was reopened (its role message already carries the handles) or when the Planner itself ran `roles` or `relaunch-role.sh` (it sees the handles in their output). If the message cannot be sent, the kickoff log says so; ask the Planner to run `cat` on the worktree's `orca-roles.env`.

`roles` also reopens a role whose tab is still there but whose agent stopped (for example after `Ctrl+C`), and one whose tab you closed with the X: Orca keeps that session running without a tab ("orphaned"), so the kit ends it and opens a new tab. This check works for the agents Orca recognizes (Claude, Codex); for `custom` agents only the tab counts.

## Creating a new role

```bash
new-role                               # saves it in your installation
new-role --repo ~/path/orca-role-hook  # saves it in your clone of the repo, to version it
```

The wizard asks everything it needs and updates the configuration:

- **Identity:** id, tab title and a **description** for the Planner (what it does and when to use it). The Planner receives that description at startup and fits the role into the flow.
- **Modes:** whether the role belongs to all [modes](#modes) or to one (`1` all, `2` one, then the mode). For a role in academic-writer (alone or in all modes) it also asks its phase: experiment, writing or both (the default); the other modes have no phases.
- **Agent:** `claude`, `codex` or `custom` (with its command), exact model and permission mode. For a `custom` agent it also asks for its `modelError` pattern and its `models` (`list`, `parse`, `probe`); empty answers leave them out.
- **MCP and tools** (with `claude`): which servers it loads, with the option to define new servers; allowed tools and extra folders.
- **Other:** extra arguments, environment variables, role parameters, tab position and whether it is enabled.
- **Prompt, one per mode** (all three for a role in all modes): generated from a few questions (steps, limits, report contents and whether it issues a verdict), copied from a file of yours, or written in your editor (`$EDITOR`, `nano` by default); from the second mode on you can also copy the prompt of the previous mode. In every case the result follows the [common prompt structure](#prompt-structure); if you copy a file that does not follow it, the wizard warns you.

Before saving it shows you a summary. It keeps a copy of the previous configuration (`.bak`).

| Mode | Prompt | Configuration |
|---|---|---|
| Local | `~/.orca-roles/roles/<mode>/<id>.md`, one per mode (not deleted when the kit is updated); the `prompt` field maps each mode to its file | `~/.orca-roles/config.json` |
| `--repo` | `prompts/<mode>/<id>.md` in the clone (the folder is created if missing); no `prompt` field, the default path works | `config.default.json` in the clone; offers to reinstall and reminds you to commit |

Every worker also receives its mode's common rules (`prompts/<mode>/common-workers.md`). To edit a role later, change its entry in the configuration and its prompt file, or run `new-role` again with the same id to overwrite it.

**Removing a role:** `new-role --remove <id>` removes a role you created (its entry and the prompt it has for every mode, plus the old `roles/<id>.md` of earlier versions; previous configuration in `.bak`). Only those exact kit paths are deleted: a prompt your configuration points to elsewhere is left alone and reported. Overwriting a role (same id) that now has fewer modes deletes the prompts of the modes it lost in your installation; with `--repo` it only lists them with the `git rm` command, since they are versioned files. The ids `planner` and `common-workers` are reserved, and with `--repo` a new role cannot take over an existing `prompts/<mode>/<id>.md`. Default roles are not removed, because the next update would bring them back: disable them with `"enabled": false`. To close a role's tab in the current workspace, run `~/.orca-roles/bin/close-role.sh <role>` from the worktree (the Planner does it for you when you ask it to remove a role).

**Without questions:** `new-role --from-json <file>` creates the role from a JSON file with `id`, `description` and `prompt` required, and the same optional fields as a role in the configuration (including `modelError` and `models`, which are validated: an invalid one stops it with nothing written), plus `after` (position) and `overwrite: true` to replace an existing one, and `phases` (academic-writer only, a non-empty list of `experiment`/`writing`; refused for a role of another mode). `modes` is `"all"` or one mode id (a string or a one-element list; missing = `"programmer"`). `prompt` is Markdown text for a role with one mode, or an object `{"<mode>": "<Markdown>"}` that covers exactly the role's modes (all three for `"all"`); anything else is rejected and nothing is written. Example: `{"id": "rv", "description": "...", "modes": "pr-reviewer", "prompt": "# Role: RV\n..."}` writes `roles/pr-reviewer/rv.md`. It is what the Planner uses with its skill.

## The Planner's skill

The Planner loads the `orca-roles` plugin (in `~/.orca-roles/plugin`), which brings the **`team`** skill (the same one you can install in any Claude Code session, see [Start here](#start-here-get-claudes-help-with-the-setup)): a guide to the kit itself so it can help you install, configure and use it without leaving the conversation. Ask it in plain language, or invoke it with `/orca-roles:team`. It covers:

- **Installation and updates**: it tells you what to run (it does not run it).
- **Registering a project** (Settings or `roles-yaml`) and the **configuration**: `config.json`, `.orca-roles.json` and the setup script exceptions, and which one suits each case.
- **Creating agents**: it asks what it needs, writes the prompt with the common structure, shows it to you and saves it with `new-role --from-json`.
- **Changing a role's behavior** at three levels, and it always asks which one you want:

  | Level | Where it is saved | How long it lasts |
  |---|---|---|
  | On the fly | Nowhere: it includes it in the tasks it assigns to that role | As long as the Planner's session |
  | This worktree | `orca-roles.notes/<role>.md` in the worktree's git dir; the kit adds it to the worker's role message | As long as the worktree exists, even if the worker is cleaned or restarted |
  | Permanent | `~/.orca-roles/config.json` and the prompts in `~/.orca-roles/roles/` | Every new worktree (the hook reads the configuration when each one is created) |

- **Applying the changes in the current workspace**: opens a new role's tab with `launch.sh`, closes one with `close-role.sh` (the only ways the Planner can open or close tabs) or resends a worker's role with `clean.sh`.
- **Removing a role**: closes its tab and, if you want it gone for good, removes it (`new-role --remove`) or disables it if it is a default role.
- **Diagnosis**: which log to look at depending on the symptom.

Before writing any kit file or opening tabs, the Planner explains what it will change and what it affects, and waits for your confirmation. It never does it because a worker asks for it. So it can edit the configuration, it starts with access to `~/.orca-roles` (the planner's `extraDirs`).

The skill is a Claude Code skill. If the Planner uses another agent, its prompt tells it to read the same file (`~/.orca-roles/plugin/skills/team/SKILL.md`). Any Claude role can load its own plugins with the `pluginDirs` field.

## Configuration

All the configuration lives in `~/.orca-roles/config.json`. It is read every time a worktree is created, so there is no need to reinstall after editing it. It is the everyday configuration; for a specific project's exceptions there are [`.orca-roles.json`](#per-project-configuration) and the [setup script options](#exceptions-in-the-setup-script).

```json
{
  "settings": {
    "launchWaitSeconds": 15,
    "kickoffTimeoutSeconds": 180,
    "jiraHandoff": true,
    "closeComposerAgent": true,
    "composerAgentWindowSeconds": 180,
    "cleanWorkersAfterStep": true,
    "language": "auto"
  },
  "defaults": {
    "agent": "claude",
    "permissionMode": "auto",
    "mcp": [],
    "allowedTools": ["Bash(orca orchestration:*)", "Read"],
    "extraDirs": [], "extraArgs": [], "env": {}, "params": {}
  },
  "mcpServers": {
    "context7": { "type": "http", "url": "https://mcp.context7.com/mcp" },
    "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest"] }
  },
  "roles": {
    "dev": { "title": "Dev", "enabled": true, "model": "claude-sonnet-5-5", "mcp": ["context7"] },
    "tester": { "title": "Tester", "enabled": true, "model": "claude-sonnet-5-5",
                "params": { "maxNewTests": 10, "maxWorkers": 2, "timeoutMinutes": 10 } }
  }
}
```

### Modes

The kit has three fixed modes (not configurable): `programmer`, `pr-reviewer` and `academic-writer`. The mode decides which team a worktree launches and which prompts it reads (`prompts/<mode>/`). All three exist; a mode is available when `prompts/<mode>/planner.md` exists (a mode whose folder lacks it fails with `mode '<x>' is not available yet`). Without any setting the mode is `programmer` and everything works as before.

Choose it, from lowest to highest priority:

1. `settings.mode` in `config.json` (default `"programmer"`).
2. `settings.mode` in the project's `.orca-roles.json`.
3. `launch.sh --mode <mode>` (or `roles --mode <mode>`): saved in the worktree's exceptions, so `roles` re-applies it when resuming; `--reset` forgets it. `--set settings.mode=<mode>` is checked the same way, and is saved like `--mode`.

The id must be exactly one of the three (no uppercase, spaces, slashes or `..`); anything else stops `launch.sh` before any tab opens. The saved mode is kept when later options do not mention it (`roles --enable x` stays in the same mode); `--mode` or `--set settings.mode=<mode>` (the same request, saved the same way) change it and `--reset` drops it.

**Open team rule:** the mode of a worktree cannot change while its team is open. If the requested mode differs from the one the worktree was launched with and any tab of the saved team still exists (also one Orca restored after a restart with a new handle), `launch.sh` stops with an error and changes nothing. Close the team first (`close-role.sh` on each worker, or close the tabs) and run `roles` again.

Each role has `modes`: `"all"` or a list of mode ids; without it the role belongs to `["programmer"]`. In `config.default.json` the `planner` is `"all"`, the `auditor` is `["programmer", "pr-reviewer"]`, the `researcher` is `["programmer", "academic-writer"]`, the other four programmer workers are `["programmer"]` and the seven academic-writer roles are `["academic-writer"]`. Only the enabled roles that belong to the mode open (the planner always does), and `--only`, `--enable` or `--disable` with a role outside the mode is an error naming the mode. An unknown id or a wrong type in `modes` is an error too.

`prompt` is a path (legacy form, it applies to `programmer` only) or an object per mode:

```json
"reviewer": { "modes": ["pr-reviewer", "programmer"], "prompt": { "pr-reviewer": "~/my/reviewer.md" } }
```

A mode without an entry uses `prompts/<mode>/<role>.md`. A role of the mode whose prompt file does not exist is skipped with a warning naming the role, the mode and the expected path (the other roles still launch). The common rules come from the mode's folder (`prompts/<mode>/common-workers.md`).

> Update needed if you set a custom `prompt` pointing to the old flat `~/.orca-roles/prompts/<role>.md`: that file no longer exists, the prompts moved to `prompts/programmer/<role>.md`.

#### pr-reviewer mode

The pr-reviewer mode follows lens-review (https://github.com/romerox3/lens-review), a Claude Code plugin skill for multi-agent code review. orca-roles does not include or copy it: on the first start of the mode the Planner installs the plugin from its own repository, with your yes, and reads it at run time to set up the reviewer roles and run each review. The review method and its lenses belong to that project, and every report credits it.

The mode's Planner reads that skill to review pull requests. `settings.prReviewer` names it: `marketplace` (`romerox3/lens-review`), `plugin` (`lens-review@lens-review`) and `skill` (the skill's path inside the plugin, `skills/lens-review/SKILL.md`). `~/.orca-roles/bin/review-skill.sh status` tells whether it is installed (`installed`, `disabled`, `missing` or `error`), `path` prints the skill file and `install` adds the marketplace and installs the plugin with the `claude` CLI. The mode's Planner asks you before installing it, the first time the mode starts; `roles` never installs it.

**Starting it.** `roles --mode pr-reviewer` in the worktree (the mode is saved, so a plain `roles` keeps it). With the default configuration it opens the PLANNER and the AUDITOR only; the reviewers are created on the first run.

**First start.** The Planner checks the skill with `review-skill.sh status`. If it is missing, it tells you what installing does (adds the marketplace and installs the plugin into your Claude Code, for all your sessions) and runs `review-skill.sh install` only after your yes; if it is disabled, it asks you to enable it (`claude plugin enable <plugin>`). It then reads the skill itself (the skill's text is not copied into the kit) and, from it, proposes one lens role per lens (`lens-correctness`, `lens-security`, `lens-tests`, `lens-architecture`) with the model the skill suggests. On your yes it creates them with `new-role --from-json` (mode `pr-reviewer`, `extraDirs` set to the plugin's version-independent folder, `review-skill.sh root`, so any agent type can read the skill and an update does not break the roles) and opens them. Roles created with an older, versioned path are re-created on your yes. They are ordinary roles in your configuration: change their models or agent whenever you like. `claude` and `codex` work as they are; a `custom` lens role needs `addDirFlag` so it can be given that folder.

**Reviewing a PR.** Give the Planner a PR (number or URL). It reads it with `gh`, checks that the worktree is at the PR's head commit and completes with you what the skill's intake requires (intent, tests run, size, tier). It dispatches one task per lens role of the tier, sends each finding to a different lens role to validate it and synthesizes with the skill's report template. The report is shown to you in the conversation and saved in the Planner's scratch folder.

**Auditor (optional).** If you ask, the Auditor tries to reproduce each confirmed finding in a copy of the worktree and reports reproduced, not reproduced or could not try, with the evidence.

**Read-only team.** Nobody edits the worktree, commits or pushes. The Planner never approves, requests changes or merges, and posts to the PR only after you approve that exact text.

#### academic-writer mode

A team that takes a scientific paper from the state of the art to the final text, in your git repository. The paper is always in English, LaTeX and BibTeX.

**Phases.** Two phases, `experiment` (always first) and `writing`; only the roles of the current phase open (the Researcher is open in both, but in writing it only fixes tables and figures). The Planner switches with `~/.orca-roles/bin/phase.sh <experiment|writing>` after your yes: it refuses with uncommitted changes, closes the roles the new phase does not have and opens its own; going back to experiment needs `STATE.md` committed at the repository root (the writing state to resume from). The phase is saved like the worktree's other exceptions (`roles --reset` forgets it and the team starts again in experiment). A role's `phases` (`["experiment"]`, `["writing"]` or both; missing = both) only matters in this mode.

| Tab | Phase | Model | Role |
|---|---|---|---|
| **State-of-the-Art** | experiment | Haiku 5.5 | Literature search with `scholar.sh`, one card per paper, references and PDFs. |
| **Researcher** | experiment, writing (tables and figures only) | Opus 5.5 | `PLAN.md`, reproducible experiments, tables and figures by script; HPC jobs only with your approval of each. In writing it only fixes tables and figures: it changes their scripts and regenerates them from the existing results. |
| **Methodology** | experiment | Opus 5.5 | Design and statistics review, read-only. |
| **Tech-Verifier** | experiment | Opus 5.5 | Math and reproducibility review, read-only. |
| **Writer** | writing | Opus 5.5 | The LaTeX paper, compiled after every change. |
| **Evidence** | writing | Sonnet 5.5 | Claims, citations and numbers against their sources, read-only. |
| **Rigor** | writing | Opus 5.5 | Conclusions, notation, figures and tables, read-only. |
| **Style** | writing | Sonnet 5.5 | Structure and language, read-only. |

Plus the Planner (both phases). There is no Auditor in this mode.

**Starting it.** `roles --mode academic-writer` in a worktree of the paper's repository (git is required: the launch stops otherwise). Each launch creates the folders below where missing and adds the lines that keep large or copyrighted files out of git to `.gitignore`; it never overwrites anything.

**Repository layout.**

```
STATE.md                         # the writing state to resume from (written when going back to experiment)
experimentation/
├── PLAN.md
├── environment.yml              # or requirements.txt
├── configs/
├── data/                        # out of git, README.md tracked
├── models/                      # out of git, README.md tracked
├── src/
├── scripts/                     # run scripts and Slurm jobs
├── results/                     # results/raw/ out of git
└── logs/                        # out of git
article/
├── main.tex
├── sections/
├── refs.bib
├── Makefile
├── literature/                  # review.md, manifest.tsv, missing.md, pdfs/ (out of git)
├── tables/
├── images/
├── template/                    # put the venue's .cls/.bst here
├── build/                       # out of git
├── supplementary.tex
├── cover_letter.tex
└── revision/                    # reviews.md, main_correction.tex, rebuttal_letter.tex
```

Tables and figures are generated by scripts from `results/`, never by hand.

**Flow.** Experiment: intake → state of the art (the PDFs that are not open access are listed in `article/literature/missing.md` with the exact file name; download them yourself into `article/literature/pdfs/` and the role picks them up with `scholar.sh pdfs`) → plan agreed with you and reviewed by Methodology before anything runs → experiments → review by Methodology and Tech-Verifier. Writing: skeleton on the venue's template → each section drafted by the Writer, reviewed by Evidence and Rigor, then Style (findings on tables and figures go to the Researcher, scripts and regeneration only; one that needs a new or repeated run means going back to experiment, with your yes) → final pass (including `scholar.sh verify`) → response to reviewers (changes marked in blue by hand in `main_correction.tex`, `rebuttal_letter.tex` answering every numbered comment). The Planner makes every commit, each one on your yes; workers never commit. HPC jobs are prepared by the Researcher and submitted only after your yes to that job (by the Researcher or by you, you decide each time). Nothing leaves the repository (push, submission, upload, email) without your yes. Names of people may appear in the paper itself (its text, author list, `refs.bib`, the literature cards), never in commit messages, PRs or Jira.

**scholar.sh.** `~/.orca-roles/bin/scholar.sh` is the team's only way to get references and PDFs (curl, jq and awk; no install).

| Command | What it does |
|---|---|
| `search "<query>" [--from] [--to] [--type article\|proceedings\|preprint] [--publisher] [--venue] [--oa] [--sort relevance\|date\|citations] [--limit N] [--source openalex\|arxiv\|s2\|all]` | OpenAlex and arXiv (Semantic Scholar too when `S2_API_KEY` is set), one TAB-separated line per paper; `--publisher` (IEEE, Elsevier, Springer, ACM…) and `--venue` (with aliases such as NeurIPS, ICML, ICLR) are resolved to OpenAlex ids and the choice is printed. |
| `show <id>` | Metadata, all authors and the abstract. |
| `bibtex <id> [--add] [--bib <path>]` | The entry only from doi.org (arXiv through its DataCite DOI, which keeps the original year), re-keyed as surname+year+word, title in braces; `--add` appends it to `article/refs.bib` without duplicating a DOI and never touches the existing entries. |
| `verify [--bib <path>]` | Re-checks each entry's title, first author and year against Crossref or arXiv and flags retractions; one line per entry, exit 4 when any entry has a problem. |
| `pdf <id>` | The paper must already be in refs.bib (`bibtex <id> --add`); the PDF takes its key. A legal open-access copy (arXiv, Unpaywall, OpenAlex) into `article/literature/pdfs/<key>.pdf`, accepted only if it is a real PDF; otherwise listed in `missing.md`. |
| `pdfs` | Picks up the PDFs you dropped by hand and updates the manifest. |

Ids: `doi:<doi>` (or a bare DOI / doi.org URL), `arxiv:<id>` (or an arxiv.org/abs URL), `openalex:W<id>`.

**Keys and contact** (environment variables, read only, never written anywhere): `OPENALEX_API_KEY` (free; without it OpenAlex allows only a small number of searches a day), `S2_API_KEY` (optional, Semantic Scholar; without it its relevance search is not usable), `SCHOLAR_EMAIL` (your email: required for Unpaywall, also sent to the APIs in the User-Agent; never sent to the sites PDFs are downloaded from). Keys travel in request headers read from a file, never in URLs or the process list. IEEE and Elsevier papers are found through OpenAlex and Crossref; their full text is not open, so they end up in `missing.md` unless an open copy exists.

**Optional MCP.** For computer-science venues, [mcp-dblp](https://github.com/szeider/mcp-dblp) (MIT) gives DBLP search and DBLP's own BibTeX from a local index (about 1.3 GB on first start, according to its README); the kit does not install it: `claude mcp add mcp-dblp -- uvx mcp-dblp`, then add it to the State-of-the-Art role's `mcp` list if you want that role to use it.

### Enabling and disabling roles

Change `enabled` in the role. The `planner` is always enabled even if you set `false`. For a single project, use the [per-project configuration](#per-project-configuration).

```json
"e2e-tester": { "enabled": false }
```

### Role options

Each role inherits from `defaults` whatever it does not define.

| Field | What it does |
|---|---|
| `enabled` | Enables or disables the role (the `planner` is always enabled). |
| `title` | Name of the tab and of the role the Planner sees. |
| `description` | What the role does and when to use it. The Planner receives it at startup; essential in roles you create. |
| `prompt` | The role's instructions file (by default `prompts/<mode>/<role>.md`). A path (programmer only) or `{ "<mode>": "<path>" }`. Accepts `~`. See [Modes](#modes). |
| `modes` | `"all"` or a list of the modes the role belongs to (default `["programmer"]`). See [Modes](#modes). |
| `phases` | academic-writer only: the phases the role opens in, `["experiment"]`, `["writing"]` or both (missing = both). The other modes have no phases. See [academic-writer mode](#academic-writer-mode). |
| `agent` | Which CLI is launched: `claude`, `codex` or `custom`. |
| `model` | Exact model passed to the agent. |
| `modelError` | Only with `agent: "custom"`: an ERE (`grep -E`) the agent prints when its model does not exist; `{model}` stands for the escaped model id. Without it, a missing model is not detected for that role. |
| `models` | `{ "list", "parse", "probe" }`, for `models.sh` (see [Models of a role](#models-of-a-role)): `list` is a command that prints the models, `parse` how to read it (`lines`, `json:<jq filter>` or `regex:<ERE with one group>`), `probe` a command that exits 0 only if the model works (`{model}` is replaced, quoted). Custom agents only (claude and codex roles have built-in listing and probes); in `defaults` or in a role. Unknown keys are rejected. |
| `permissionMode` | In `claude`, the `--permission-mode` (`auto`, `acceptEdits`, `manual`...). `default` means not passing the flag. In `codex`, `auto` is `--sandbox workspace-write --ask-for-approval on-request` (what `--full-auto` was); any other value passes nothing. |
| `mcp` | `"all"` for the agent to use its own MCP configuration (in `claude`, all your connectors), or a list of `mcpServers` names (`[]` = none). Works with any agent: see [MCP in other agents](#mcp-in-other-agents). |
| `allowedTools` | Tools allowed without asking. `claude` only. |
| `extraDirs` | Extra folders the agent can access (`--add-dir`, one per folder). Accepts `~` and `{kit}`. `claude` and `codex` (in codex the folders are writable because the kit pre-trusts the worktree, which makes the default mode `workspace-write` too); in `custom` only with `addDirFlag`. |
| `extraArgs` | Additional arguments, as they are, for the CLI. In `custom` they are appended to the command. |
| `env` | Environment variables for that agent (`defaults.env` and the role's are merged). The Tester and the Auditor come with thread caps (`OMP_NUM_THREADS`, `GOMAXPROCS`, `MAKEFLAGS=-j2`...) and `CUDA_VISIBLE_DEVICES=` so they do not saturate the CPU or use the GPU. |
| `nice` | CPU priority of the agent and everything it runs (`nice -n`): the Tester and the Auditor run at 10, so their test and mutation runs yield to you and to the other roles. `0` or absent: normal priority. |
| `params` | Parameters passed to the role in its startup message (the Tester's limits and `maxSelfMutants`, the Auditor's `maxMutants` and `rejectSeverity`, the E2E-Tester's `evidenceDir`...). Each prompt documents its own and their default value. `scratchDir` is added automatically (the role's scratch folder, see below); it is not set in the configuration. |
| `command` | Only with `agent: "custom"`: command to run. Accepts `{model}`, `{prompts}`, `{prompt}`, `{mcp}`, `{scratch}` and `{anchor}`. |
| `addDirFlag` | Only with `agent: "custom"`: the agent's flag to give it access to a folder (e.g. `"--add-dir"`). If set, `<flag> <scratch folder>` and `<flag> <dir>` for each `extraDirs` entry are appended to the command, quoted. Without it, `extraDirs` does not apply to `custom`. |
| `trust` | Only with `agent: "custom"`: how to mark the worktree as trusted so the agent does not stop at a trust dialog: `{"file": "<path>", "jq": "<filter>"}`. `file` accepts `~`, `{kit}` and `{home}`; the `jq` filter receives the worktree's real path as `$dir` and must return the whole (modified) object, exactly one JSON object: anything else (an array, `null`, nothing, several values) is rejected with a warning and the file is left untouched. Before opening the tabs the kit applies it once per distinct file and filter, with the same care as `~/.claude.json` (permissions and symlinks kept, concurrent changes not lost, nothing written if it is already applied or the file does not exist). |
| `pluginDirs` | Claude Code plugins that role loads (`--plugin-dir`). Accepts `~` and `{kit}`. The planner brings `{kit}/plugin`, with its skill. `claude` only. |
| `clearCommand` | Command that opens a new conversation in the agent, for context cleanup. By default `/clear` in `claude` and `/new` in `codex`; in `custom` it must be defined or the role is not cleaned. |

The order of the tabs is the order of the roles in the JSON.

### Models of a role

`~/.orca-roles/bin/models.sh <role|title> [--check]` lists the models a role can use and, with `--check`, tests them. When a role's model does not exist (see Troubleshooting), the Planner's fix steps can use it to find one that works. `--model <m>` replaces the candidates with exactly `<m>`, with or without `--check`.

**Relaunching a role with another model:** `~/.orca-roles/bin/relaunch-role.sh <role|title> --model <m> [--no-check]`, from the worktree, is what the Planner runs after your yes. It tests the model first (`models.sh <role> --check --model <m>`; it stops without changing anything unless the model is `ok`, or `--no-check`), closes the role's tab and runs `launch.sh --set roles.<id>.model=<m>`. The worktree's other saved exceptions are kept; launch.sh reopens every tab of the team that is missing (normally just this role's), and kicks only the roles it opened. The model is saved for the worktree (`roles --reset` forgets it). The Planner cannot be relaunched.

- Without `--check` it only prints the candidates, one per line, the role's own model first. Nothing is run against a model and nothing is spent.
  - `claude`: Claude Code cannot list the models of your login, so these are its aliases (`sonnet`, `opus`, `haiku`, `fable`).
  - `codex`: the models `codex debug models` marks as listed.
  - `custom`: the output of the role's `models.list` command, read as `models.parse` says.
- With `--check` it runs one minimal probe per candidate, in parallel (at most 6 probes at a time, each bounded to 90 seconds), and prints `<model>`, `ok` with the resolved id, `unavailable` (the model does not exist or you have no access) or `unknown` with the reason (not logged in, offline, timed out...). Only `ok` and `unavailable` are answers.
- Cost of `--check`: a Claude probe for a model that does not exist costs nothing; for one that works, at most about 0.012 USD the first time (it answers "ok" with no tools). Codex probes use your Codex login. The probes use the role's `env`, write nothing outside a temporary folder except the agents' own logs (Codex keeps its logs even for ephemeral runs) and never change a setting. The list commands are bounded to 90 seconds as well.

For a `custom` role, describe how to list and test models in `models`:

```json
"tester": { "agent": "custom", "command": "opencode --model {model}", "model": "m1",
  "models": { "list": "opencode models", "parse": "lines", "probe": "opencode run --model {model} ok" } }
```

`parse` is `lines` (default: each non-empty line), `json:<jq filter>` (for example `json:.data[].id`) or `regex:<ERE with one group>` (the group of each matching line). Without `list` the role's `model` is the only candidate; without `probe`, `--check` answers `unknown`.

### Using other agents

```json
"dev":    { "agent": "codex", "model": "<codex-model>" },
"tester": { "agent": "custom", "command": "opencode --model {model}", "model": "<model>" }
```

The roles receive their instructions the same way as with Claude (the kit types into their terminal when they are ready), so they work with any agent with a terminal interface that can read files and run `orca orchestration`.

With `agent: "custom"`:

- The `command` runs with `bash -lc`, that is, in a login shell with your profile's PATH (nvm, brew, etc.).
- Placeholders: `{model}` → `model` field; `{prompts}` → the `~/.orca-roles/prompts` folder; `{prompt}` → path of the role's prompt file (useful if the role lives in `~/.orca-roles/roles/`); `{mcp}` → file with the role's MCP servers (empty with `mcp: "all"`); `{scratch}` → the role's scratch folder, created before launching (also in `ORCA_ROLES_SCRATCH`); `{anchor}` → the line that makes the agent ask for its role again after its conversation is cleared, for its system prompt flag (also in `ORCA_ROLES_ANCHOR`; see [Cleaning the workers' context](#cleaning-the-workers-context)). The values are quoted automatically.
- `extraArgs`, `env` and `mcp` do apply, and so do `addDirFlag` (with `extraDirs`) and `trust`. `permissionMode` and `allowedTools` do not: they are Claude Code's. Pass the equivalent in the `command` itself or with `extraArgs`.
- The agent must be able to read `~/.orca-roles/prompts` (and `~/.orca-roles/roles` if you use your own roles) on its own: the kit only passes it the scratch folder and `extraDirs`, and only with `addDirFlag`.
- Accepting the trust dialog and closing the composer's extra session look for Claude Code's texts; with another agent they are not detected, but the startup works the same.

Codex (`agent: "codex"`):

- `permissionMode: "auto"` runs it with `--sandbox workspace-write --ask-for-approval on-request`. The role's scratch folder and each `extraDirs` entry are always passed as `--add-dir` (they are writable only with `workspace-write`).
- Every codex role needs codex >= 0.48 (`--add-dir` is passed in every mode).
- The trust dialog is answered with a single `-c 'projects={"<worktree>" = {trust_level = "trusted"}}'` override: nothing is written to `~/.codex/config.toml`.
- Checked with Codex 0.162 without a session that uses a model: it rejects `--full-auto`, accepts the flags above, and with the `-c projects` override it opens without the trust dialog and writes nothing to its `config.toml`. Whether the `--add-dir` folders are writable in a real session was not measured.

Antigravity (`agy`) has no trust flag and no sandbox that lets it write only in some folders. Example:

```json
"dev": { "agent": "custom", "command": "agy --dangerously-skip-permissions --model {model}", "model": "<model>",
         "addDirFlag": "--add-dir",
         "trust": { "file": "~/.gemini/antigravity-cli/settings.json",
                    "jq": ".trustedWorkspaces = ((.trustedWorkspaces // []) + [$dir] | unique)" } }
```

**Warning:** the only way we measured for `agy` to write without asking is `--dangerously-skip-permissions`, which lets it write anywhere, not only in the worktree (`--mode accept-edits` and `permissions.allow` are alternatives we did not measure); `--add-dir` gives it read access only, and `--sandbox` makes everything read-only. Use it only for roles you accept that for.

### MCP in other agents

`mcpServers` defines the servers once and `mcp` picks which ones each role loads, whatever its agent. The kit generates a `{"mcpServers": {...}}` file per role with the chosen ones and hands it to each agent the way that agent can receive it:

| Agent | How it receives it |
|---|---|
| `claude` | `--strict-mcp-config --mcp-config <file>`. With `"all"` nothing is passed and Claude Code uses all your connectors. |
| `codex` | One `-c mcp_servers.<name>.<field>=<value>` override per field (`command`, `args`, `url`, `env`), without touching `~/.codex/config.toml`. With `"all"` it uses its own configuration. **Not verified against a Codex installation**: if your version does not accept `url` or the format changes, use `extraArgs` or its `config.toml`. |
| `custom` | The `{mcp}` placeholder in `command` and the `ORCA_ROLES_MCP` variable point to the file. The `mcpServers` format is the one Cursor and Gemini CLI also read; for an agent with another format, convert the file in a wrapper script. |

With this the Planner is not tied to Claude. By default, `mcpServers` includes `atlassian` (the official remote MCP, `https://mcp.atlassian.com/v1/sse`, which asks for OAuth in the agent the first time). The default Planner uses `"all"` because with Claude Code that loads your already authorized connectors; to move it to another agent, give it the servers by name:

```json
"planner": { "agent": "codex", "model": "<model>", "mcp": ["atlassian", "context7"] }
```

The E2E-Tester still needs the `playwright` server, which is a local process (`npx @playwright/mcp`): it works in any agent that can start it.

### Placeholders in `mcpServers`

In the `args`, `env` and `url` of any server they are expanded when each role starts:

| Placeholder | Value |
|---|---|
| `{worktree}` | Absolute path of the worktree |
| `{project}` | Name of the main repo's folder (not the worktree's) |
| `{evidenceDir}` | `params.evidenceDir` of the role (or of the E2E-Tester, or `qa-evidence`) |
| `{browserState}` | `~/.orca-roles/browser/{project}.json`, the session saved by `browser-login.sh` (created empty if missing) |
| `{kit}`, `{home}` | `~/.orca-roles` and your `$HOME` |

The default `playwright` server uses them like this:

```json
"playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@latest", "--headless", "--isolated",
                                          "--storage-state", "{browserState}", "--output-dir", "{worktree}/{evidenceDir}"] }
```

To see the browser in a project, remove `--headless` in its `.orca-roles.json` (lists are replaced whole, so copy the other args).

### Per-project configuration

A `.orca-roles.json` at a repo's root is merged on top of your global configuration for that project only. It is looked up at the worktree root and, if missing, at the main checkout root, so it works even if you do not commit it. For example, for a library without an API:

```json
{ "roles": { "e2e-tester": { "enabled": false }, "deployer": { "enabled": false } } }
```

Objects are merged field by field; lists are replaced whole.

### Exceptions in the setup script

Without creating any file, you can add options to the `launch.sh` line in the project's setup script (Settings → Repository, or the `orca.yaml` of `roles-yaml`). They are applied on top of `config.json` and `.orca-roles.json`:

```
$HOME/.orca-roles/bin/launch.sh --disable e2e-tester,deployer
```

| Option | What it does |
|---|---|
| `--only a,b` | Only those roles; the `planner` always runs. |
| `--enable a,b` | Enables roles disabled in the configuration. |
| `--disable a,b` | Disables roles. The `planner` cannot be disabled. |
| `--set path=value` | Changes any configuration key. The path uses dots and the value is read as JSON if it is JSON (`true`, `10`, `["x"]`) and as text otherwise. |
| `--mode <mode>` | The team's mode (`programmer`, `pr-reviewer`, `academic-writer`); beats `settings.mode` and `.orca-roles.json`. Rejected if the worktree's team is open in another mode. See [Modes](#modes). |
| `--reset` | Forgets the worktree's saved exceptions first, so only the options of this run apply (only with `roles`). |
| `--status` | Shows the team and exits; it changes nothing in the worktree or Orca and opens nothing. First line `Mode: <mode>`, then one tab-separated line per role: `<Title>`, handle, state (`alive`, `no tab`, `agent gone`, `orphaned`), configured model (`-` if none) and model in use from `orca-roles.models` (`FAILED:<model>` as recorded, `-` if not recorded). Without a launched team: `No team launched in this worktree.` |

`--set` examples: `roles.dev.model=claude-opus-5-5`, `settings.jiraHandoff=false`, `settings.language=Spanish`, `roles.tester.params.maxNewTests=5`, `roles.dev.mcp='["context7"]'`.

- They can be combined and repeated: `--only dev,tester --set roles.dev.model=claude-opus-5-5`. They are applied in this order: `--only`, `--enable`, `--disable`, `--set` and finally `--mode`.
- If an option names a role that does not exist, `launch.sh` fails with the list of available roles instead of starting halfway.
- The exceptions are saved per worktree (`orca-roles.overrides.json` in its git dir). So `roles` without options applies them again when resuming after a restart; new options are added to them (the same option replaces its saved value: `--only`, `--mode`, a `--set` path; a role in `--enable` leaves the saved `--disable` and the other way round); a `--mode` different from the saved one also drops the saved `--only`/`--enable`/`--disable` (role selections belong to a mode; the saved `--set`s are kept); with `--reset`, it forgets them and goes back to the normal configuration, or starts over with the options given with it.
- They also work with `roles` in a workspace terminal (`roles --enable e2e-tester`). They only decide which tabs open: disabling a role whose tab is already open does not close it.

### General settings (`settings`)

| Field | What it does |
|---|---|
| `launchWaitSeconds` | Maximum time the setup waits for Orca to have the worktree ready (it moves on earlier if it is). |
| `kickoffTimeoutSeconds` | Maximum time it waits for each agent to be ready to receive its role. |
| `jiraHandoff` | Pass the worktree's Jira ticket to the Planner. |
| `closeComposerAgent` | Close the extra session Orca's composer opens when you create a worktree (often a Claude tab soon renamed by Claude Code, e.g. "done"). Only in a new worktree, and only an agent tab outside the team that already existed before the team when Orca's setup script started the kit on a worktree created moments ago (whatever its title, e.g. "✳ Claude Code"), or whose **first** title was exactly the branch name or started with the Jira key (`DEVGD-220`, `DEVGD-220: summary`), or whose screen showed the key. A `roles` run by hand never closes a tab that existed before. It is closed with `orca terminal close`. If there is none, nothing is touched and it is noted in the log. |
| `composerAgentWindowSeconds` | How long that extra session is watched for after the worktree is created. |
| `cleanWorkersAfterStep` | Whether the Planner proposes cleaning the workers' context when closing each step. With `false` it only does it when you ask. |
| `mode` | The team's mode: `programmer` (default), `pr-reviewer` or `academic-writer`. See [Modes](#modes). |
| `phase` | academic-writer only: the phase (`experiment` by default or `writing`). Changed by the Planner with `phase.sh`, not by hand. |
| `language` | The language the Planner replies to you in. `"auto"` (default): the language you write in. Any other value (`"Spanish"`, `"English"`...): always that one. The prompts are in English either way. The workers always write in English (their repo artifacts follow the repo's language): for Claude workers the kit passes `--settings '{"language":"english"}'`, overriding Claude Code's own `language` setting, and every worker also gets the rule in its role anchor (the only channel for Codex and custom agents, whose own language settings are not overridden). A `--settings` in a role's `extraArgs` replaces the kit's one (claude does not merge them), so include `"language":"english"` in it. |

## Files

```
orca-role-hook/                  # this repo → installed into ~/.orca-roles/
├── install.sh
├── config.default.json          # default configuration (your copy: ~/.orca-roles/config.json)
├── bin/
│   ├── launch.sh                # setup script: opens the tabs and saves their handles
│   ├── agent.sh                 # launches a role's agent according to the configuration
│   ├── kickoff.sh               # sends each agent its role, passes the Jira ticket and closes the extra agent
│   ├── clean.sh                 # cleans the workers' context and resends their role
│   ├── checkpoint.sh            # records the tree under refs/orca-roles/checkpoints/ (the Planner's briefs diff rounds against it)
│   ├── close-role.sh            # closes a role's tab in the current workspace
│   ├── relaunch-role.sh         # relaunches one role with another model
│   ├── models.sh                # lists a role's candidate models and tests them
│   ├── review-skill.sh          # installs and locates the pr-reviewer mode's review skill
│   ├── phase.sh                 # switches an academic-writer team's phase
│   ├── academic-scaffold.sh     # creates the paper repository's folders and .gitignore lines
│   ├── scholar.sh               # scholarly search, BibTeX, verification and open-access PDFs
│   ├── scholar-arxiv.awk        # scholar.sh parser (arXiv)
│   ├── scholar-norm.jq          # scholar.sh parser (result normalization)
│   ├── scholar-bibfix.jq        # scholar.sh parser (BibTeX fixes)
│   ├── browser-login.sh         # saves your application session for the E2E-Tester
│   ├── new-role.sh              # wizard to create roles (the new-role command)
│   ├── lib.sh                   # shared functions
│   ├── orca-yaml.sh             # registers the kit in a project with a local orca.yaml (the roles-yaml command)
│   └── apply-hooks.sh           # explains at install time how to register the kit in each project
├── .claude-plugin/marketplace.json  # makes the repo a Claude Code marketplace (/plugin install orca-roles@orca-role-hook)
├── plugin/                      # Claude Code plugin the Planner loads
│   └── skills/team/SKILL.md     # guide to the kit: installation, configuration, exceptions, new agents
├── prompts/
│   ├── programmer/
│   ├── pr-reviewer/
│   └── academic-writer/         # each mode's folder holds:
│       ├── common-workers.md    # rules common to the mode's workers
│       └── <role>.md            # each role's instructions (with its review method, if it has one)
├── tests/
│   └── smoke.sh                 # tests of configuration, inheritance, merge, update and the scripts
└── .github/workflows/ci.yml     # shellcheck + smoke on every push to main and every PR
```

To change a role's behavior, edit `prompts/<mode>/<role>.md` in the repo and run the installer again. Whatever you edit directly in `~/.orca-roles/prompts/` is overwritten on update; your `config.json` and your roles in `~/.orca-roles/roles/` are not.

Inside each worktree:

- `research/` and `qa-evidence/`: the Researcher's work and the E2E-Tester's screenshots. They are ignored locally in `.git/info/exclude`, without touching your `.gitignore`.
- `refs/orca-roles/checkpoints/<worktree id>/<step>-c<n>`: the Planner's per-round snapshots of the tree (commits kept out of every branch, made without touching HEAD, the index or the files); `checkpoint.sh --list` shows them and `--clear <step>` deletes a step's and `--clear-all` every one of the worktree's (after the set's last commit). Each checkpoint's message records a creation sequence number, which the diff hints use to find the previous step's last checkpoint. Files marked assume-unchanged or skip-worktree are recorded as in the index, not as in the working tree, and `checkpoint.sh` warns about them. Renaming a worktree's folder, or moving the main checkout (its git dir moves with it), changes its id, so checkpoints taken before no longer show in `--list` or `--clear`; remove them with `git update-ref -d <ref>` (`git for-each-ref refs/orca-roles/checkpoints` lists them). Moving a linked worktree to another parent folder with `git worktree move` keeps them.
- `DEPLOYMENT.md`: the Deployer's guide. It is not committed unless you ask.
- In the worktree's git dir (`git rev-parse --git-dir`): `orca-roles.config.json` (effective configuration used), `orca-roles.overrides.json` (setup script exceptions, if any), `orca-roles.pty` (each role's terminal identity, to recognize the tabs Orca restores after a restart), `orca-roles.notes/<role>.md` (a role's instructions for this worktree only), `orca-roles-mcp-<role>.json` (MCP servers each role received), `orca-roles.env` (handles), `orca-roles.preexisting.json`, `orca-roles.composer-seen.json` and `orca-roles.setup-context` (tabs seen when the worktree was created, and whether Orca's setup script started the kit, to recognize the composer's session), `orca-roles-launch.log` and `orca-roles-kickoff.log` (startup), `orca-<service>.log` and `orca-<service>.pid` (the Deployer's local services).
- Outside the worktree: `~/.orca-roles/browser/<project>.json`, the browser session for the E2E-Tester.
- Outside the worktree too: each role's scratch folder, `~/.orca-roles/tmp/<project>-<hash of the git dir>/<role>/`, one per worktree and role, fixed (the same path every time). Agents put their temporary copies there (the Tester's mutation copy, the Auditor's experiments, the Researcher's earlier versions) and reuse it; they never delete anything in it, so Claude Code does not ask for permission on every `rm`, and the kit never empties it either. `copy/` (the copy of the current tree) stays current because every use runs `rsync -a --delete` into it; earlier versions go in `rev-<full commit hash>/` (one per commit, reused if it exists) and the Researcher's temporaries have fixed names per task, so those accumulate slowly. When a worktree is removed, its folder stays orphaned in `~/.orca-roles/tmp/`; remove it by hand when you want the space back, for example `rm -rf ~/.orca-roles/tmp/<project>-<hash>`. The role receives its path as the `scratchDir` parameter in its startup message, and Claude and Codex agents get it with `--add-dir` (`custom` agents through `{scratch}`/`ORCA_ROLES_SCRATCH` and `addDirFlag`). It is outside the worktree because jest, vitest and eslint collect copies of the project that live inside it, and none of them honors `.gitignore` or `.git/info/exclude`.
- On Windows (WSL): `~/.orca-roles/shim/orca`, the Orca CLI wrapper (see [Windows with WSL2](#windows-with-wsl2)).

## Platforms

| System | Status |
|---|---|
| **macOS** | Main platform. Works with the bash 3.2 the system ships: CI runs the tests on macOS with that bash. |
| **Linux** (Ubuntu, Debian...) | Supported: the scripts only use tools common to GNU and BSD. Depends on Orca having a version for your distribution. |
| **Windows** | With **WSL2** (see below). There is no native version for PowerShell or Git Bash: the kit is Bash scripts. |

### Windows with WSL2

Orca for Windows runs the terminals, and with them the agents and the setup script, inside WSL when the repo lives on the WSL file system. The kit installs and works there as on Linux.

1. **WSL2 with Ubuntu** (`wsl --install` in PowerShell). For `browser-login.sh` you also need WSLg (included in Windows 11 and in Windows 10 with `wsl --update`), which is what allows opening a visible browser from WSL.
2. **The repo inside WSL**, in `~/...`, not in `/mnt/c/...`: on the Windows disk git and the agents are much slower. Clone it from WSL; if you clone it from Windows with `core.autocrlf=true`, the scripts will have CRLF line endings and bash will not run them.
3. **In Orca, add the project with its WSL path**: `\\wsl.localhost\Ubuntu\home\<user>\<repo>`. That way Orca opens its terminals inside WSL.
4. **Install inside WSL, from an Orca terminal**: `sudo apt update && sudo apt install -y jq` (if it fails, the Planner's skill covers the usual WSL problems and a no-`sudo` install), Claude Code and Node inside WSL (not the Windows ones), and then the kit's installer.
5. **Register the kit in each project** with `roles-yaml` or in Settings (see [Setting up a project](#setting-up-a-project-once-per-project)).
6. **E2E-Tester**: `npx playwright install --with-deps chromium` inside WSL.

**Orca's CLI has another name.** In WSL terminals, Orca does not install `orca` but a launcher whose name is given by `$ORCA_CLI_COMMAND` (`orca-ide` in Orca 1.4.219), which calls `orca.exe` on Windows. The kit detects it and creates the `~/.orca-roles/shim/orca` wrapper, which it prepends to the PATH of its scripts and of the agents; the prompts and the permissions (`Bash(orca orchestration:*)`) keep working unchanged. That is why the CLI is only available in terminals opened by Orca: the kit's commands (`roles`, `clean.sh`, the installer) must be run from one of them. So you can also type `orca ...` yourself in those terminals, the installer adds to your `~/.bashrc` an `orca` alias to `$ORCA_CLI_COMMAND`, which only applies when that variable is set and there is no real `orca`. Do not install the `orca` package apt suggests: it is GNOME's screen reader.

The installer adds the `roles`, `new-role` and `roles-yaml` commands to `~/.zshrc` (zsh), `~/.bashrc` (bash on Linux), `~/.bash_profile` (bash on macOS) or `~/.profile` (other shells).

## Requirements

- Orca with Orchestration enabled (Settings > Experimental).
- `jq` (macOS: `brew install jq`; Ubuntu/Debian: `sudo apt install jq`). It is essential: the installer and the kit fail with a clear message if it is missing.
- Claude Code (`claude`) with `--permission-mode auto` available. The installer checks it and warns you if your version does not offer it; in that case update Claude Code or change `permissionMode` in `config.json`. Checked with 2.1.x.
- The CLIs of any other agent you configure.
- `curl` and `tar` (they come with macOS and Ubuntu), Node (`npx`, for Playwright). For the E2E-Tester, Playwright's Chromium: `npx playwright install chromium` (on Ubuntu, `npx playwright install --with-deps chromium`, which also installs the system libraries it needs and asks for sudo).

## Development

```bash
tests/smoke.sh                                   # does not touch ~/.orca-roles
tests/smoke.sh --list                            # section names
tests/smoke.sh roles-yaml mcp                    # only those sections, in that order
shellcheck -S warning install.sh bin/*.sh tests/*.sh
```

The GitHub Actions workflow runs the same on every push to main and every pull request.

## Troubleshooting

| Symptom | What to check |
|---|---|
| The tabs do not open | The worktree's `orca-roles-launch.log`, and the project's setup script |
| With `roles-yaml`, the new worktree does not start the kit | That the worktree has `orca.yaml` (if not, `.worktreeinclude` did not copy it: `git check-ignore -v orca.yaml` in the main checkout must answer), and the project's setup source (Settings → Repository): with `local-only` the Settings script wins and `orca.yaml` is ignored; `run-both` and `shared-only` do run it |
| `launch.sh` does not run in new worktrees | The project's setup source and policy: `orca repo show --repo path:<main checkout root> --json \| jq .result.repo.hookSettings`. With `local-only` (also implied when no source was chosen and Settings has a script), `orca.yaml` is ignored: put `$HOME/.orca-roles/bin/launch.sh` first in the local script or choose "run both". With `setupRunPolicy` `ask` or `skip-by-default`, setup does not run on its own |
| "Orca CLI not found" (Windows), or `Command 'orca' not found` | Run the command from an Orca terminal (outside them neither `orca` nor `$ORCA_CLI_COMMAND` exist), opened after installing or after `source ~/.bashrc`, so it has the `orca` alias. Do not install apt's `orca` package (a screen reader) |
| The agents do not receive their role | The worktree's `orca-roles-kickoff.log` |
| "Invalid configuration" | Validate your JSON: `jq . ~/.orca-roles/config.json` (and the project's `.orca-roles.json`) |
| A role never answers its first message | Its `model` may not exist: after the role message the kickoff compares the screen with what it showed before and, if a new model error appeared (Claude Code's "There's an issue with the selected model", Codex's "does not exist" API error, or the custom agent's `modelError`), records `ROLE=FAILED:<model>` in `orca-roles.models` (git dir) and sends the Planner a "model unavailable" escalation; the Planner asks you whether you fix it yourself or want it to. Nothing is switched and `config.json` is never changed: set `roles.<id>.model`, close the tab with `close-role.sh <id>` and run `roles`, or let the Planner run `relaunch-role.sh <id> --model <m>`. In a very small pane the check can miss an error (the kit reads only what the tab shows): the role's first answer tells you. Only roles with a `model` are checked |
| Which models a role can use | `~/.orca-roles/bin/models.sh <role> --check` ([Models of a role](#models-of-a-role)) |
| An agent starts with another model or MCP | `orca-roles.config.json` in the worktree's git dir shows the configuration that was used, and `orca-roles-launch.log` the exceptions applied |
| A role does not appear even though `enabled` is `true` | The worktree's saved exceptions: `orca-roles.overrides.json` in its git dir. Drop them with `roles --reset` |
| `worker-start` fails with `terminal_handle_stale` | A role's tab changed (Orca restarted or lost the window). Run `roles` in a terminal of the worktree: the Planner gets the new handles by a "Role handles changed" message |
| The Planner is not notified when workers finish | A message batch it read but did not acknowledge: Orca types no notice while one is open. `orca orchestration check --peek --json` from the Planner's tab shows the unread messages; ask the Planner to read and acknowledge its messages (`check --ack <delivery_id> --json` until `count` is 0) |
| The Planner replies in another language | `settings.language` (or a `--set settings.language=...` in the setup script); with `"auto"` it replies in the language you write in |
| An agent asks for permissions | That it is in auto mode (`Shift+Tab` shows the current mode) |
| A tab stays on Claude Code's "Do you trust the files in this folder?" dialog and never gets its role | The kit marks the worktree as trusted in `~/.claude.json` before starting the agents (`orca-roles-launch.log` says "Marked ... as trusted") and presses Enter if the dialog still shows. If a tab is stuck anyway, answer the dialog once and run `roles`; and tell us the exact text it showed |
| `roles` says "Orca is not ready (<code>)" | It could not tell whether this worktree's tabs are still open (Orca's window or runtime was not ready, or `orca terminal list` failed after a restart), and stopped without closing or opening anything. Run `roles` again once Orca is ready |
| `roles` says "another roles is still running" | Another `roles` held `orca-roles.lock` (git dir) for more than 60 seconds. Wait for it to finish and run `roles` again; a lock left by a process that died is taken over on its own |
| `roles` warns "this folder was launched before as worktree <old> and now as <new>" | Orca knows the same folder under two worktree ids (`orca-roles.wtid` in the git dir holds the last one), so its tabs may be duplicated. Close the extra tabs and launch from one id |
| After a restart there are two teams in the worktree | A kit older than `orca-roles.pty`: close the tabs that are not in `orca-roles.env` and update the kit. With the current kit, `orca-roles-launch.log` says which restored tabs it reopened with their conversation |
| Tabs in another workspace | `launch.sh` uses `ORCA_WORKTREE_ID`; you can force it with `launch.sh id:<ORCA_WORKTREE_ID>` |
| `roles` says "All roles are already open" but a tab has no agent | The agent stopped in a tab Orca does not recognize as an agent's (a `custom` agent): close that tab and run `roles` |
| After a restart, the Planner does not recover the state | `orca-roles-launch.log` must say "Resuming workspace". If not, the `orca-roles.env` file in the worktree's git dir did not exist or was empty |
| After a restart, roles come back without their memory | Claude Code was installed with npm (it runs under `node` and renaming its process to `claude` erases its `--resume` argument, so the kit cannot read the resumed session). Use the native installer |
| Cleaning a worker fails | `clean.sh` says why: dead tab (run `roles`), or a `custom` agent without `clearCommand` |
| The composer's extra session (the "done" tab) does not close | `orca-roles-kickoff.log` lists the titles it saw; if none was the branch or started with the Jira key, it was left alone. Close it by hand or disable `closeComposerAgent` |
| The E2E-Tester does not open the browser | `npx playwright install chromium` |
| The E2E-Tester sees the login screen | Run `~/.orca-roles/bin/browser-login.sh <url>` and ask the Planner to clean the E2E-Tester (`clean.sh e2e-tester`) so it starts with the new session |
| `/plugin marketplace add` says `Marketplace file not found` | The marketplace file is not on the repo's `main` branch yet: add it from your clone, `/plugin marketplace add ~/orca-role-hook` |
| A worker finished its work but the Planner never got its report | It is probably not a Claude agent and ran `orca orchestration send` in a way that never finished (for example as a background task). Look at its tab; the Planner warns you when a worker has been silent for more than 10 minutes |
| The Planner says it has no Jira tool | Its session is not authenticated with Atlassian: run `/mcp` in its tab and authenticate (see [Connecting Jira](#connecting-jira)) |
| The Planner does not receive the Jira ticket | Create the worktree from the ticket in Orca so it is linked (`orca worktree show --json` must show `linkedWorkItem`). Without a link, the branch must start with the uppercase key |
| The screenshots are not in `qa-evidence/` | Check the `--output-dir` of the `playwright` server in the worktree's `orca-roles.config.json` |
| A local service does not stop | `ls "$(git rev-parse --git-dir)"/orca-*.pid` and kill those processes |

## Known limitations

- The hook only fires when a worktree is created; in other cases (including resuming after a restart) use `roles`.
- When resuming, the roles keep their conversation only if Orca restored their tabs (see [Resuming after a restart](#resuming-after-a-restart)). If the tabs were closed before the restart, the Planner rebuilds the state from Orca and git and the decisions you made verbally that did not end up in a task are lost.
- Reading the session Orca resumed in a restored tab relies on the agent's process (`ps`); it works for Claude Code on macOS, Linux and WSL. Codex and custom agents come back without memory.
- Orca has no global setup script: it has to be configured once per project.
- Closing the composer's extra session depends on Orca first titling it with the exact branch or the Jira key (or showing the key on its screen). Claude Code renames the tab soon after, so the kit records the title each tab had when it was first seen; if Orca titles it differently from the start, it is not closed.
