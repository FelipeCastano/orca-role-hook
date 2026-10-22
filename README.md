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
| **Tester** | Sonnet 5.5 | None | Does not review: implements and runs the tests, covering each criterion as a family of inputs with its boundaries, checks them with a few mutants of its own and checks that its new tests fail on the step's base (the code without the change: `crosscheck.sh tree` builds that copy outside the worktree; a test that passes there either guards behavior the step must preserve, and is reported as a regression test, or is rewritten; `baseCheck: false` turns it off), within limits on quantity, parallelism and time, and cleans up at the end. A change that only touches prompt, README or skill text gets no text checks and no text mutants: it runs the safety-rule checks (`tests/smoke.sh rules`) and reads the diff for weakened rules, and the rest of its review still applies. |
| **Auditor** | Opus 5.5 | None | Reviews Dev's code and the Tester's tests with its code review method (including mutation, in place in the worktree with a backup and a verified restore). It audits once per set of steps, not per step. It also audits the Planner's plan, read-only, when the Planner judges it very complex. Like the Tester, it runs no text mutants on prompt-only changes. Only findings from the rejection threshold up (default `high`) reject; the rest are notes. Defaults: `maxMutants` 8 (Tester `maxSelfMutants` 3). Existing installs that still had the old defaults (15 and 5) move to the new ones on update; values you set yourself are kept (except exactly 15 and 5 themselves, which every update moves to the new defaults; to keep them, set them in the project's `.orca-roles.json`). |
| **E2E-Tester** | Opus 5.5 | Playwright | Proposes an E2E test plan for the application (front end or API) and a Playwright script for it and, once you approve the plan, runs the script in the kit's headless Chromium with your saved sessions, with screenshots and a `result.json`. |
| **Deployer** | Sonnet 5.5 | None | Starts and stops the application locally (API, front end and required services) when asked, and maintains `DEPLOYMENT.md` with the step-by-step guide for dev and prod. Never deploys. |

They all start in **auto mode**. The workers know that all their work comes from the Planner and share common rules (`prompts/programmer/common-workers.md`): do not create worktrees or terminals, do not touch git outside their worktree, do not push and clean up whatever they start.

Every role also follows the written-report rules (`prompts/<mode>/reports.md`, which a worker reads only when a task asks for a report, so the common prompt stays short; the Planner keeps its own copy in `planner.md`) whenever the user asks for a report in any format: descriptive titles, an outline the user approves before writing, an aggregated level of detail, a formal tone and no names of people. Worker messages, commit messages, pull requests and Jira keep their own formats.

This is the programmer team; see [pr-reviewer mode](#pr-reviewer-mode) and [academic-research mode](#academic-research-mode) for the other teams.

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

**Briefed rounds.** After every Dev or Tester report the Planner records the tree with `checkpoint.sh <step> <n>` and creates the next worker's task with a brief: the task (goal, criteria, threat model) and the state (files changed, what Dev and the Tester did and found, what earlier rounds already verified, the findings still open). The first brief carries the whole step's diff (from the previous step's last checkpoint, or from HEAD for the first step of the set) and later ones only what changed since that role last looked (`git diff <earlier checkpoint> <latest checkpoint>`), so the Tester does not rebuild the step from zero in every round; every Tester brief also names the step's base ref (the start of that first diff), against which the Tester runs its base check; the brief is information, never instructions on what to test, and they still verify the code themselves. The Planner keeps a ledger per step (`ledger-<step>.md` in its scratch folder) as the source of every brief and clears all the checkpoints after the set's last commit.

If a role is disabled in the configuration, the Planner skips its part of the flow and tells you when a step would have needed it.

## Installation

Clone the repo and run the installer from the clone:

```bash
git clone git@github.com:FelipeCastano/orca-role-hook.git && bash orca-role-hook/install.sh
```

It installs into `~/.orca-roles/`, creates your `~/.orca-roles/config.json`, adds the `roles`, `new-role` and `roles-yaml` commands to your shell and explains how to register the kit in your projects. **To update**, pull the changes and run the installer again: your configuration is kept (values and order of your roles) and only the new options are added. A `visual-tester` role from older versions becomes `e2e-tester` with its settings, and the mode `academic-writer` becomes `academic-research` (see the [note on the rename](#academic-research-mode)). Update the kit with no team open, or clean the open teams' context afterwards (see [Cleaning the workers' context](#cleaning-the-workers-context)), because running agents keep the old prompt paths.

```bash
git -C orca-role-hook pull && bash orca-role-hook/install.sh
```

It can also be installed without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/FelipeCastano/orca-role-hook/main/install.sh | bash
```

The installer takes no options: roles are enabled and disabled with `enabled` in `config.json` (see [Configuration](#configuration)).

**Pinning a version.** The download installs `main` unless you say otherwise. `ORCA_ROLES_REF` takes a branch, a tag or a commit sha (`ORCA_ROLES_BRANCH` still works and is used when `ORCA_ROLES_REF` is not set):

```bash
curl -fsSL https://raw.githubusercontent.com/FelipeCastano/orca-role-hook/v1.0.0/install.sh | ORCA_ROLES_REF=v1.0.0 bash
```

Use the same ref in the script URL and in the variable, so the installer and the files it installs match. The installer records what it installed in `~/.orca-roles/VERSION` (the kit's version) and `~/.orca-roles/.installed` (one line: `<source>@<ref>`, plus the commit when it is known without a network call: from a local clone, `local@<branch> <sha>` with `-dirty` appended if the clone has uncommitted changes, or when the ref is a full sha). `roles --status` prints both as its first line: `Kit: 1.0.0 (local@main 2263b1d...)`; `unknown` replaces a part that is missing.

**Your edits to the kit's files.** `bin/`, `prompts/`, `plugin/` and `mcp/` are regenerated on every install. The installer keeps a checksum list (`~/.orca-roles/.manifest`); on the next install, any file in those folders that you modified or added since the last one is first copied to `~/.orca-roles/backup/<UTC timestamp>/` (same relative path) and listed in a `WARNING`. It never stops or asks (it also runs through `curl | bash`), and a file you deleted is simply restored. Without a manifest (first install, or a kit from before this feature) nothing is compared. To keep a prompt change, put it in your own role (see `new-role`) or in `~/.orca-roles/roles/`, which are never touched.

The first time, the E2E-Tester's browser must be installed with `~/.orca-roles/bin/e2e-browser.sh install` (see [E2E testing](#e2e-testing-browser-session-and-screenshots)).

**A second copy of the kit.** The installer always installs into `~/.orca-roles` (the shell aliases point there). Every other script reads the `KIT` variable and falls back to `~/.orca-roles`, so a checkout can run on its own, for example one under test, without touching the installed kit: `KIT=/path/to/checkout /path/to/checkout/bin/launch.sh`. The tabs it opens then run `KIT=/path/to/checkout /path/to/checkout/bin/agent.sh <role>`, and the sub-scripts it starts use the same copy. With the default location the commands are exactly the same as before. Known limits: the prompts and the hints they print still name `~/.orca-roles/bin/...` (a Planner running a second copy has to add `KIT=<path>` itself), and `orca-yaml.sh` (`roles-yaml`) still writes `$HOME/.orca-roles/bin/launch.sh` into `orca.yaml`.

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
roles-yaml                        # to undo it: roles-yaml --remove
roles-yaml --mode pr-reviewer     # every new worktree starts in that mode (see Modes)
roles-yaml --all --dry-run          # preview: register the kit in every project of Orca at once
```
It creates an `orca.yaml` with the setup script at the main checkout's root and lists it in `.worktreeinclude`. Both stay ignored in `.git/info/exclude`, the local equivalent of `.gitignore`: the project's `.gitignore` is not touched, there is nothing to commit and your teammates see nothing. It works because Orca copies the ignored files listed in `.worktreeinclude` to every new worktree, before looking for its setup script. It only affects the worktrees you create from now on.

With `--mode <mode>` (one of the kit's modes) the setup line becomes `$HOME/.orca-roles/bin/launch.sh --mode <mode>`, so every new worktree of the project starts in that mode. An invalid or missing value stops with the valid modes and writes nothing; `--mode` cannot be combined with `--remove` or `--check`. Running `roles-yaml` again updates the line the kit generated: another `--mode` changes the mode, and running it without `--mode` drops it (back to the default mode); if nothing differs it says nothing changed. The mode is local like the file itself: nothing to commit. Existing worktrees keep the mode they have: use `roles --mode <mode>` in them.

**All projects at once.** `roles-yaml --all [--mode <mode>] [--under <dir>] [--dry-run]` (from any folder) registers the kit in every project registered in Orca, whatever its project group; `--under <dir>` limits it to the projects inside that folder (`/a/b` never matches `/a/bc`). **Run it with `--dry-run` first**: nothing is written, and each line says what would happen (`would create`, `would update to mode X`, `unchanged`, `skipped: <reason>`). It prints one line per project and a final `Summary: N created, N updated, N unchanged, N skipped, N errors`; it exits 0 if no project errored, 1 if one did, and 2 if the project list cannot be read. Without `--mode` it only registers the projects that have no kit `orca.yaml` yet (in the default mode) and leaves every already registered project, and its mode, untouched; with `--mode <mode>` every project is registered or updated to that mode, exactly as `roles-yaml --mode <mode>` in it. Projects that cannot be registered are skipped with their reason: `path-missing` (a remote project shows up like this), `not-a-repo`, `not-main-checkout` (a linked worktree or a folder inside a repo), `committed-orca-yaml`, `foreign-orca-yaml`, `committed-worktreeinclude`, `local-only-policy`, `local-script`. It covers only the projects registered in Orca at that moment: a project added later needs `roles-yaml` in it. `--all` cannot be combined with `--remove` or `--check`.

A single-project run ends with a last line `ROLES_YAML_RESULT=<created|updated|unchanged|skipped:<reason>|error:<reason>>` for scripts.

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

**Stack.** The E2E-Tester does not use Orca's embedded browser. It plans and explores with the Playwright MCP and delivers each E2E as a Playwright script, all on the kit's own pinned stack: the pinned `@playwright/mcp` and `@playwright/test` packages in `~/.orca-roles/pw` and their Chromium in `~/.orca-roles/browsers`. Install it once with `~/.orca-roles/bin/e2e-browser.sh install` (`npm ci` plus the pinned Chromium: network, about 400 MB, no sudo; on Linux, system libraries need a `sudo` command that is only printed for you to run); `e2e-browser.sh check` tells whether it is installed (it starts no browser; exit 0 ready, 2 and the fix if not). Screenshots are requested over the protocol, they are not screen captures, so they work even if the window is behind others or does not exist. By default the browser is **headless**: you can keep working while it tests.

**Sessions.** If your application requires a login (Entra, Google, MFA...), sign in yourself once:

```bash
~/.orca-roles/bin/browser-login.sh https://localhost:5173
```

It opens a visible browser (the kit's pinned Chromium; if the stack is not installed it stops and tells you to run `e2e-browser.sh install`), you wait for the application to load with your session, you close the window and the session (cookies and localStorage) is saved in `~/.orca-roles/browser/<project>/default.json`. The session is written to a temporary file and replaces the previous one only if it holds a cookie for the URL's host or localStorage for its origin (the same match as `e2e-browser.sh session`); otherwise (for example, you closed the window while still at the identity provider) nothing is saved, the command exits with an error and the previous session stays as it was. Cookies are matched by host, not port, so with a local identity provider on the same host (for example Keycloak on `localhost:8080` and the app on `localhost:5173`) the check cannot tell an abandoned login from a finished one: confirm the login finished before closing the window. The E2E-Tester's MCP starts with it in isolated mode: nothing is written to disk during the test and several worktrees can test at the same time. If the application asks it to log in, the E2E-Tester does not try to authenticate: it tells the Planner, which will ask you to run the command and will launch the task again. Only you log in and save sessions; the E2E-Tester never does.

**Identities.** To keep several users of the same project (an admin and a regular user, for example), save each one under its own name with `--as`: `~/.orca-roles/bin/browser-login.sh https://localhost:5173 --as admin` saves `~/.orca-roles/browser/<project>/admin.json`. An identity is lowercase letters, digits and hyphens, starting with a letter or digit; without `--as` it is `default`. The project name can still be given as the second argument (`browser-login.sh <url> <project> --as <identity>`). The E2E-Tester's MCP always uses the `default` identity; flows can use any saved identity (`e2e-run.sh --as`).

**Preflight.** Before any E2E work the Planner runs `~/.orca-roles/bin/e2e-browser.sh check`. If the stack is missing it tells you what is missing and asks whether the Deployer installs it (`e2e-browser.sh install`: network, about 400 MB, no sudo; on Linux, system libraries need a `sudo` command that is only printed for you to run); without a Deployer it gives you the command. `e2e-browser.sh install` ends with `check`. Only the Deployer, with your yes, runs the install; the E2E-Tester never installs anything. After an install the E2E-Tester's tab is reopened (`close-role.sh e2e-tester`, then `roles`) so its Playwright MCP connects. Then, for each identity the E2E plan needs, the Planner runs `~/.orca-roles/bin/e2e-browser.sh session <base-url> [--as <identity>] [project]`. It starts no browser and only reads the saved session, and prints one line and the exact login command when it is not `ok`:

| Exit | Result | Meaning |
|---|---|---|
| 0 | `ok` | the file has, for the URL's host, a persistent cookie that has not expired, or localStorage for the URL's origin (it prints the save date and the earliest cookie expiry) |
| 1 | | usage error or invalid identity |
| 3 | `missing` | no file, or the empty stub |
| 4 | `no-session-for-host` | the file has sessions, but none for that host (cookies match by host or domain, including a leading-dot domain; localStorage by exact `scheme://host:port`) |
| 5 | `expired` | every persistent cookie for the host has expired and there is no localStorage for the origin |
| 6 | `unknown` | only session cookies (no expiry) for the host and no localStorage: it cannot tell |

Anything but `ok`: the Planner asks you to run the printed `browser-login.sh` command in a worktree terminal and checks again. The session file is read each time a browser context starts, so the Planner does not clean the E2E-Tester after a login.

**Earlier versions.** The single session file of earlier versions (`~/.orca-roles/browser/<project>.json`) is moved to `<project>/default.json` automatically when the roles start or when you run `browser-login.sh`, as long as there is no session in `default.json` yet; if there is, the old file is left in place and a warning names both.

It depends on your application keeping the session in cookies or `localStorage`; if it keeps it in `sessionStorage`, it does not survive. Tokens expire according to your identity provider: when the E2E-Tester sees the login screen again, run the command again.

**Screenshots.** They go to `<evidenceDir>/step-<N>/` in the worktree (by default `qa-evidence/`, locally ignored by git) thanks to `--output-dir`. **Network.** To validate payloads, the E2E-Tester injects a hook on XHR/fetch with `browser_evaluate` and reads the bodies from the page; it never logs headers.

**Flows.** The Playwright MCP only explores. For each E2E the E2E-Tester delivers, with its plan, a Playwright script (a *flow*) in `<e2eDir>/<flow>/` of the worktree (`e2eDir` is a parameter of the E2E-Tester, `qa-e2e` by default; the flow name is kebab-case), as `*.flow.ts` (`import { test, expect } from '@playwright/test'`) or `*.flow.js` (`require`). Once you approve the plan, it runs the script in one command and steps in only on a failure:

```bash
~/.orca-roles/bin/e2e-run.sh <flow> [--as <identity>] [--timeout <seconds>] [--list] [-- key=value ...]
```

- **Inputs.** `key=value` pairs reach the flow as `JSON.parse(process.env.E2E_PARAMS || '{}')` (strings; a value may contain `=`). `--timeout` is per test (default 60 s); the whole run is limited to that times the number of flow files times 5, at least 300 s.
- **List.** `--list` only runs `playwright test --list` on the flow: it checks that the script compiles and shows its tests, starts no browser, runs nothing and needs no session.
- **Identities.** `--as <identity>` starts the flow with that saved session and stops with the login command if it is missing or empty. Without it the flow uses the `default` session if there is one, and none otherwise.
- **Evidence.** In `<evidenceDir>/<flow>/`: `report.json` (Playwright's), screenshots in `step-<N>/`, network captures (method, URL, status, bodies, never headers) in `network/`, and `result.json`, written by the flow: one `{step, item, expected, got, result}` per check, `result` being `PASS` or `FAIL`. The verdict comes from `result.json` and the review of the screenshots.
- **Stack.** The script runs on the kit's pinned `@playwright/test` and Chromium (`e2e-run.sh` first runs `e2e-browser.sh check`). It links `<e2eDir>/node_modules` to the kit's packages and writes `<e2eDir>/package.json` (`{"private": true, "type": "commonjs"}`) if missing; if `<e2eDir>/node_modules` is a real folder it stops instead of replacing it.
- **Writes to shared services.** If the plan writes to a shared backend (DEV, PRE), the Planner asks you to type the authorization in the E2E-Tester's tab before the execution.

**Type checks and linters.** The kit keeps `<e2eDir>/` out of git but cannot keep it out of the project's tools: if your `tsconfig` includes `**/*.ts` or your eslint lints every `*.ts`, they will also check `<e2eDir>/*.flow.ts`; add `<e2eDir>` (`qa-e2e` by default) to the `tsconfig` excludes or the eslint ignores.

**Regression.** The flow is the regression: rerun it with `e2e-run.sh` while the UI does not change. Flows and evidence live in the worktree and are lost with it (copy the folder to keep one); they are never committed. The kit adds `/<e2eDir>/` and `<evidenceDir>/` to the repository's `info/exclude` when the roles start, and warns if files under `<e2eDir>/` are already tracked by git.

All of this is configured in the `playwright` server of `mcpServers`; see [placeholders](#placeholders-in-mcpservers) to remove `--headless` or change paths. When the kit updates and changes its default `playwright` entry, a configuration that still has the previous default is moved to the new one; a customised entry is kept as it is, and saved worktree overrides of `mcpServers.playwright` are not migrated (drop them with `roles --reset` or the specific `--set` path).

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
- **Modes:** whether the role belongs to all [modes](#modes) or to one (`1` all, `2` one, then the mode). For a role in academic-research (alone or in all modes) it also asks its phase: experiment, writing or both (the default); the other modes have no phases.
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

**Without questions:** `new-role --from-json <file>` creates the role from a JSON file with `id`, `description` and `prompt` required, and the same optional fields as a role in the configuration (including `modelError` and `models`, which are validated: an invalid one stops it with nothing written), plus `after` (position) and `overwrite: true` to replace an existing one, and `phases` (academic-research only, a non-empty list of `experiment`/`writing`; refused for a role of another mode). `modes` is `"all"` or one mode id (a string or a one-element list; missing = `"programmer"`). `prompt` is Markdown text for a role with one mode, or an object `{"<mode>": "<Markdown>"}` that covers exactly the role's modes (all three for `"all"`); anything else is rejected and nothing is written. Example: `{"id": "rv", "description": "...", "modes": "pr-reviewer", "prompt": "# Role: RV\n..."}` writes `roles/pr-reviewer/rv.md`. It is what the Planner uses with its skill.

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
    "playwright": { "command": "{kit}/pw/node_modules/.bin/playwright-mcp", "args": ["--browser", "chromium", "--headless"],
                    "env": { "PLAYWRIGHT_BROWSERS_PATH": "{kit}/browsers" } }
  },
  "roles": {
    "dev": { "title": "Dev", "enabled": true, "model": "claude-sonnet-5-5", "mcp": ["context7"] },
    "tester": { "title": "Tester", "enabled": true, "model": "claude-sonnet-5-5",
                "params": { "maxNewTests": 10, "maxWorkers": 2, "timeoutMinutes": 10 } }
  }
}
```

### Modes

The kit has three fixed modes (not configurable): `programmer`, `pr-reviewer` and `academic-research`. The mode decides which team a worktree launches and which prompts it reads (`prompts/<mode>/`). All three exist; a mode is available when `prompts/<mode>/planner.md` exists (a mode whose folder lacks it fails with `mode '<x>' is not available yet`). Without any setting the mode is `programmer` and everything works as before.

Choose it, from lowest to highest priority:

1. `settings.mode` in `config.json` (default `"programmer"`).
2. `settings.mode` in the project's `.orca-roles.json`.
3. `roles-yaml --mode <mode>`: the project's local, uncommitted `orca.yaml` runs `launch.sh --mode <mode>`, so every new worktree of the project starts in that mode (existing worktrees keep theirs; run it without `--mode` to drop it).
4. `launch.sh --mode <mode>` (or `roles --mode <mode>`): saved in the worktree's exceptions, so `roles` re-applies it when resuming; `--reset` forgets it. It beats the mode of the project's setup line, also for worktrees created with it: an explicit `roles --mode` in a worktree is saved per worktree. `--set settings.mode=<mode>` is checked the same way, and is saved like `--mode`.

The id must be exactly one of the three (no uppercase, spaces, slashes or `..`); anything else stops `launch.sh` before any tab opens. The saved mode is kept when later options do not mention it (`roles --enable x` stays in the same mode); `--mode` or `--set settings.mode=<mode>` (the same request, saved the same way) change it and `--reset` drops it.

**Open team rule:** the mode of a worktree cannot change while its team is open. If the requested mode differs from the one the worktree was launched with and any tab of the saved team still exists (also one Orca restored after a restart with a new handle), `launch.sh` stops with an error and changes nothing. Close the team first (`close-role.sh` on each worker, or close the tabs) and run `roles` again.

Each role has `modes`: `"all"` or a list of mode ids; without it the role belongs to `["programmer"]`. In `config.default.json` the `planner` is `"all"`, the `auditor` is `["programmer", "pr-reviewer"]`, the `researcher` is `["programmer", "academic-research"]`, the other four programmer workers are `["programmer"]` and the seven academic-research roles are `["academic-research"]`. Only the enabled roles that belong to the mode open (the planner always does), and `--only`, `--enable` or `--disable` with a role outside the mode is an error naming the mode. An unknown id or a wrong type in `modes` is an error too.

`prompt` is a path (legacy form, it applies to `programmer` only) or an object per mode:

```json
"reviewer": { "modes": ["pr-reviewer", "programmer"], "prompt": { "pr-reviewer": "~/my/reviewer.md" } }
```

A mode without an entry uses `prompts/<mode>/<role>.md`. A role of the mode whose prompt file does not exist is skipped with a warning naming the role, the mode and the expected path (the other roles still launch). The common rules come from the mode's folder (`prompts/<mode>/common-workers.md`).

> Update needed if you set a custom `prompt` pointing to the old flat `~/.orca-roles/prompts/<role>.md`: that file no longer exists, the prompts moved to `prompts/programmer/<role>.md`.

#### Trust of the folder

Claude Code warns about a repository's hooks, MCP servers and settings the first time it starts in a folder ("Do you trust the files in this folder?"). With `settings.trust: "worktree"` the kit skips that warning: before the tabs open it marks the worktree in `~/.claude.json` (`projects[<path>].hasTrustDialogAccepted`), Codex gets a trust override, and the kickoff presses Enter if the dialog still shows. That is fine for your own code. With `settings.trust: "never"` the kit marks nothing: `roles` prints one line saying so, and each agent shows the dialog.

The default is `"worktree"` in every mode, as before this setting existed. `"never"` is opt-in: it suits `pr-reviewer` on branches you do not trust (`roles --set settings.trust=never`), at the cost of answering the dialog in each tab. With it the kickoff waits for you instead of answering: it prints `<title>: waiting for you to answer the trust dialog in its tab` and types nothing until Orca reports Claude Code running in the tab (Orca's `agentIdentity`, which only appears once the folder is trusted; up to `kickoffTimeoutSeconds`), and then sends the role. It does not go by the screen: the tab's shell can look idle before Claude Code has drawn the dialog, Orca's screen text does not always show it, and anything typed into it answers it (Claude Code then exits). Codex tabs still go by the screen. If the time runs out it does not type anything: the role stays unsent, and the next `roles` run sends it to the tabs that never got it.

**Cleaning up.** Every folder the kit marks is recorded in `~/.orca-roles/trusted.list` (only when the kit changed `~/.claude.json`; an entry you made yourself is not recorded). `~/.orca-roles/bin/forget-trust.sh`, from a worktree, removes that worktree's entry from `~/.claude.json` and from the list; `forget-trust.sh --stale` does the same for every recorded folder that no longer exists, and never touches anything the kit did not record. `--dry-run` with either prints what would be removed and writes nothing. A missing or invalid `~/.claude.json` is a warning, never an error. The trust of custom agents (role field `trust`) is not cleaned: its filter is opaque to the kit.

#### pr-reviewer mode

The pr-reviewer mode follows lens-review (https://github.com/romerox3/lens-review), a Claude Code plugin skill for multi-agent code review. orca-roles does not include or copy it: on the first start of the mode the Planner installs the plugin from its own repository, with your yes, and reads it at run time to set up the reviewer roles and run each review. The review method and its lenses belong to that project, and every report credits it.

The mode's Planner reads that skill to review pull requests. `settings.prReviewer` names it: `marketplace` (`romerox3/lens-review`), `plugin` (`lens-review@lens-review`) and `skill` (the skill's path inside the plugin, `skills/lens-review/SKILL.md`). `~/.orca-roles/bin/review-skill.sh status` tells whether it is installed (`installed`, `disabled`, `missing` or `error`), `path` prints the skill file and `install` adds the marketplace and installs the plugin with the `claude` CLI. The mode's Planner asks you before installing it, the first time the mode starts; `roles` never installs it.

**Starting it.** `roles --mode pr-reviewer` in the worktree (the mode is saved, so a plain `roles` keeps it). With the default configuration it opens the PLANNER and the AUDITOR only; the reviewers are created on the first run.

**First start.** The Planner checks the skill with `review-skill.sh status`. If it is missing, it tells you what installing does (adds the marketplace and installs the plugin into your Claude Code, for all your sessions) and runs `review-skill.sh install` only after your yes; if it is disabled, it asks you to enable it (`claude plugin enable <plugin>`). It then reads the skill itself (the skill's text is not copied into the kit) and, from it, proposes one lens role per lens (`lens-correctness`, `lens-security`, `lens-tests`, `lens-architecture`) with the model the skill suggests. On your yes it creates them with `new-role --from-json` (mode `pr-reviewer`, `extraDirs` set to the plugin's version-independent folder, `review-skill.sh root`, so any agent type can read the skill and an update does not break the roles) and opens them. Roles created with an older, versioned path are re-created on your yes. They are ordinary roles in your configuration: change their models or agent whenever you like. `claude` and `codex` work as they are; a `custom` lens role needs `addDirFlag` so it can be given that folder.

**Reviewing a PR.** Give the Planner a PR (number or URL). It reads it with `gh`, checks that the worktree is at the PR's head commit and completes with you what the skill's intake requires (intent, tests run, size, tier). It dispatches one task per lens role of the tier, sends each finding to a different lens role to validate it and synthesizes with the skill's report template. The report is shown to you in the conversation and saved in the Planner's scratch folder.

**Auditor (optional).** If you ask, the Auditor tries to reproduce each confirmed finding in a copy of the worktree and reports reproduced, not reproduced or could not try, with the evidence.

**Read-only team.** Nobody edits the worktree, commits or pushes. The Planner never approves, requests changes or merges, and posts to the PR only after you approve that exact text.

#### academic-research mode

This mode was called `academic-writer`. The old name still works until the next version: wherever it is read, the team opens as academic-research and `roles` prints one line saying where the old name was found (the Planner relays it at startup). It is accepted in `settings.mode` (`config.json` and `.orca-roles.json`), `roles --mode`, the worktree's saved options, `roles-yaml --mode` and `new-role`. Updating the kit (`install.sh`) migrates `~/.orca-roles/config.json`, moves `~/.orca-roles/roles/academic-writer/` (if you have it) to `roles/academic-research/` (a file that already exists there is kept and named in a warning) and leaves it as a link to the new folder, and `prompts/academic-writer` is always left as a link to the new folder, so open teams and old paths keep working. `roles-yaml --all` updates the uncommitted orca.yaml files it generated. `.orca-roles.json` files in projects and orca.yaml files not generated by the kit are never changed: update them by hand.

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

**Starting it.** `roles --mode academic-research` in a worktree of the paper's repository (git is required: the launch stops otherwise). Each launch creates the folders below where missing and adds the lines that keep large or copyrighted files out of git to `.gitignore`; it never overwrites anything.

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
| `phases` | academic-research only: the phases the role opens in, `["experiment"]`, `["writing"]` or both (missing = both). The other modes have no phases. See [academic-research mode](#academic-research-mode). |
| `agent` | Which CLI is launched: `claude`, `codex`, `opencode` or `custom`. |
| `model` | Exact model passed to the agent. |
| `modelError` | With `agent: "custom"` (or `"opencode"`, which also checks `opencode models`, see [OpenCode roles](#opencode-roles)): an ERE (`grep -E`) the agent prints when its model does not exist; `{model}` stands for the escaped model id. Without it, a missing model is not detected for that role. |
| `models` | `{ "list", "parse", "probe" }`, for `models.sh` (see [Models of a role](#models-of-a-role)): `list` is a command that prints the models, `parse` how to read it (`lines`, `json:<jq filter>` or `regex:<ERE with one group>`), `probe` a command that exits 0 only if the model works (`{model}` is replaced, quoted). Custom agents only (claude and codex roles have built-in listing and probes); in `defaults` or in a role. Unknown keys are rejected. |
| `permissionMode` | In `claude`, the `--permission-mode` (`auto`, `acceptEdits`, `manual`...). `default` means not passing the flag. In `codex`, `auto` is `--sandbox workspace-write --ask-for-approval on-request` (what `--full-auto` was); any other value passes nothing. |
| `mcp` | `"all"` for the agent to use its own MCP configuration (in `claude`, all your connectors), or a list of `mcpServers` names (`[]` = none). Works with any agent: see [MCP in other agents](#mcp-in-other-agents). |
| `allowedTools` | Tools allowed without asking. `claude` only. Separately, every `claude` role except the Planner gets `--disallowedTools` rules that deny the Edit tool on the kit's `prompts/`, `roles/`, `bin/`, `plugin/`, `config.json` and `config.default.json`: `--add-dir` gives workers write access under `permissionMode: "auto"`, and what they wrote there would reach every later worker. Scratch folders (`~/.orca-roles/tmp/`) stay writable. It is a guard on Claude Code's file tools and on the file commands it recognizes in Bash (`sed -i`, `tee`, redirections), not a sandbox: a script that opens the files itself is not stopped. |
| `extraDirs` | Extra folders the agent can access (`--add-dir`, one per folder). Accepts `~` and `{kit}`. `claude` and `codex` (in codex the folders are writable because the kit pre-trusts the worktree, which makes the default mode `workspace-write` too); in `custom` only with `addDirFlag`. |
| `extraArgs` | Additional arguments, as they are, for the CLI. In `custom` they are appended to the command. |
| `env` | Environment variables for that agent (`defaults.env` and the role's are merged). The Tester and the Auditor come with thread caps (`OMP_NUM_THREADS`, `GOMAXPROCS`, `MAKEFLAGS=-j2`...) and `CUDA_VISIBLE_DEVICES=` so they do not saturate the CPU or use the GPU. |
| `nice` | CPU priority of the agent and everything it runs (`nice -n`): the Tester and the Auditor run at 10, so their test and mutation runs yield to you and to the other roles. `0` or absent: normal priority. |
| `params` | Parameters passed to the role in its startup message (the Tester's limits, `maxSelfMutants` and `baseCheck`, the Auditor's `maxMutants` and `rejectSeverity`, the E2E-Tester's `evidenceDir`...). Each prompt documents its own and their default value. `scratchDir` is added automatically (the role's scratch folder, see below); it is not set in the configuration. |
| `command` | Only with `agent: "custom"`: command to run. Accepts `{model}`, `{prompts}`, `{prompt}`, `{mcp}`, `{scratch}` and `{anchor}`. |
| `addDirFlag` | Only with `agent: "custom"`: the agent's flag to give it access to a folder (e.g. `"--add-dir"`). If set, `<flag> <scratch folder>` and `<flag> <dir>` for each `extraDirs` entry are appended to the command, quoted. Without it, `extraDirs` does not apply to `custom`. |
| `trust` | Only with `agent: "custom"`: how to mark the worktree as trusted so the agent does not stop at a trust dialog: `{"file": "<path>", "jq": "<filter>"}`. `file` accepts `~`, `{kit}` and `{home}`; the `jq` filter receives the worktree's real path as `$dir` and must return the whole (modified) object, exactly one JSON object: anything else (an array, `null`, nothing, several values) is rejected with a warning and the file is left untouched. Before opening the tabs the kit applies it once per distinct file and filter, with the same care as `~/.claude.json` (permissions and symlinks kept, concurrent changes not lost, nothing written if it is already applied or the file does not exist). |
| `pluginDirs` | Claude Code plugins that role loads (`--plugin-dir`). Accepts `~` and `{kit}`. The planner brings `{kit}/plugin`, with its skill. `claude` only. |
| `clearCommand` | Command that opens a new conversation in the agent, for context cleanup. By default `/clear` in `claude` and `/new` in `codex` and `opencode`; in `custom` it must be defined or the role is not cleaned. |
| `opencode` | Only with `agent: "opencode"`: `{"steps": <positive integer>, "permissions": [{"action": ..., "resource": ..., "effect": "allow"\|"ask"\|"deny"}, ...]}`. `steps` caps the agent's steps (default: `settings.flow.maxStepsPerWorker`, else no cap); `permissions` are appended after the kit's own rules. See [OpenCode roles](#opencode-roles). |
| `common` | Workers only: path of the common rules file the worker reads instead of its mode's `common-workers.md`. Accepts `~`, `{kit}` and `{home}`. If the file does not exist, the worker gets `common-workers.md` and a warning goes to stderr. Unset = today's behaviour. See [Compact rules for small models](#compact-rules-for-small-models). |

The order of the tabs is the order of the roles in the JSON.

#### Compact rules for small models

`prompts/programmer/common-peon.md` is an opt-in condensed version of `common-workers.md` (about 3 KB instead of 8) for small open models run as workers, where a long standing instruction competes with the task. Point a role at it with `"common": "{kit}/prompts/programmer/common-peon.md"`; no role does by default. It keeps the hard rules in the same words (no worktrees or terminals, work only in your worktree, no push, no commit unless asked, nothing written to external systems, no AI attribution, no names of people, `scratchDir` for temporary files, no `bash -c`, stop what you started), the communication contract (one `worker_done`, no heartbeats, ack batches) and English output. It drops the long recipes: the `git archive` extraction of earlier versions is one line, the commit-history matching detail is one line (match `git log -15`), and the comment-density guidance is one line. Whether it helps small models is not measured yet.

### Models of a role

`~/.orca-roles/bin/models.sh <role|title> [--check]` lists the models a role can use and, with `--check`, tests them. When a role's model does not exist (see Troubleshooting), the Planner's fix steps can use it to find one that works. `--model <m>` replaces the candidates with exactly `<m>`, with or without `--check`.

**Relaunching a role with another model:** `~/.orca-roles/bin/relaunch-role.sh <role|title> --model <m> [--no-check]`, from the worktree, is what the Planner runs after your yes. It tests the model first (`models.sh <role> --check --model <m>`; it stops without changing anything unless the model is `ok`, or `--no-check`), closes the role's tab and runs `launch.sh --set roles.<id>.model=<m>`. The worktree's other saved exceptions are kept; launch.sh reopens every tab of the team that is missing (normally just this role's), and kicks only the roles it opened. The model is saved for the worktree (`roles --reset` forgets it). The Planner cannot be relaunched.

- Without `--check` it only prints the candidates, one per line, the role's own model first. Nothing is run against a model and nothing is spent.
  - `claude`: Claude Code cannot list the models of your login, so these are its aliases (`sonnet`, `opus`, `haiku`, `fable`).
  - `codex`: the models `codex debug models` marks as listed.
  - `opencode`: the output of `opencode models` (one `provider/model` per line); `--check` only tests that the model is in that list, so it costs nothing. A role's `models.list` / `models.probe` replace these.
  - `custom`: the output of the role's `models.list` command, read as `models.parse` says.
- With `--check` it runs one minimal probe per candidate, in parallel (at most 6 probes at a time, each bounded to 90 seconds), and prints `<model>`, `ok` with the resolved id, `unavailable` (the model does not exist or you have no access) or `unknown` with the reason (not logged in, offline, timed out...). Only `ok` and `unavailable` are answers.
- Cost of `--check`: a Claude probe for a model that does not exist costs nothing; for one that works, at most about 0.012 USD the first time (it answers "ok" with no tools). Codex probes use your Codex login. The probes use the role's `env`, write nothing outside a temporary folder except the agents' own logs (Codex keeps its logs even for ephemeral runs) and never change a setting. The list commands are bounded to 90 seconds as well.

For a `custom` role, describe how to list and test models in `models`:

```json
"tester": { "agent": "custom", "command": "my-agent --model {model}", "model": "m1",
  "models": { "list": "my-agent models", "parse": "lines", "probe": "my-agent ping --model {model}" } }
```

`parse` is `lines` (default: each non-empty line), `json:<jq filter>` (for example `json:.data[].id`) or `regex:<ERE with one group>` (the group of each matching line). Without `list` the role's `model` is the only candidate; without `probe`, `--check` answers `unknown`.

### Metrics and provenance

The goal is to measure before changing anything. Two things are recorded, both in the worktree's git dir and never sent anywhere:

- **Provenance.** Each time `agent.sh` starts a role, right before it runs the agent, it appends one JSON line to `orca-roles.provenance.jsonl`: `ts` (UTC), `role`, `agent`, `model` (the configured one), `cliVersion` (first line of `claude --version` / `codex --version`, with a short time limit; `null` for `custom`), `configSha` (sha1 of the effective configuration it read), `promptSha` (sha1 of the role's prompt file), `kit` (`VERSION`) and `installed` (`.installed`); `null` for what is not known. Writing is best-effort and never stops the agent; outside a git repository nothing is written. `roles --status` shows the last line of each role as its last two columns (`<agent>@<cliVersion>`, first 7 characters of `promptSha`). `orca-roles.models` (the model in use) is unchanged.
- **Metrics.** `~/.orca-roles/bin/metrics.sh [--since <ISO date>] [--save]`, from the worktree, prints one JSON line per role and session (read-only; `--save` also appends them to `orca-roles.runs.jsonl`). Tokens only, no prices. For Claude it reads `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<dir>/<sessionId>.jsonl`, where `<dir>` is the worktree's physical path with every `/` and `.` replaced by `-`, and keeps the lines whose `cwd` is that worktree. Line: `{"agent","role","session","model","version","first","last","turns","input","output","cacheRead","cacheWrite"}`. A `/clear` starts a new session, so a role can have several lines.
  - **Which role a session is.** The first `user` line whose text contains the kit's role message (`Read <...>/<role>.md and adopt that role`, with `common-*.md` ignored); no match gives `unknown`. Limits: it reads the message, not the prompt's content, so a role whose prompt file is named differently from its id is reported under the file's name; a session whose first message was not sent by the kit (a role started by hand, or a Claude Code version that stores the message differently) is `unknown`; and a conversation resumed with `--resume` keeps the role of its first message.
  - **What it relies on** in Claude Code's session files (an internal format, not a contract): per line `type`, `sessionId`, `cwd`, `version`, `timestamp`; on assistant lines `message.model` and `message.usage.{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens}`; on user lines `message.content` as a string or a list of `{type:"text",text}`. If a version changes these names, the numbers will be zero or missing, not wrong.
  - **OpenCode** is added only when `opencode` is on the PATH and some role runs it (`agent: opencode`, or a `custom` command starting with `opencode`): one line `{"agent":"opencode","role":null,"raw":<opencode stats --json --cost --project .>}`, with a time limit (`ORCA_ROLES_METRICS_TIMEOUT`, 30 s). It cannot be split per role (the statistics are per project, not per session of a role), so do not read it as one. If the command fails, a warning goes to stderr. Codex is not measured yet.

### Optional oracle

Off by default. A Tester's verdict is an opinion; the oracle is a command whose exit code decides. When `settings.oracle.enabled` is `true` (programmer mode only), the Planner asks for an `## Acceptance command` section in every Dev task spec and, after each Dev `worker_done`, runs `~/.orca-roles/bin/oracle.sh --task <id> --spec-file <spec>` before briefing the Tester. `pass` or `pass_flaky` go on to the Tester; anything else goes back to Dev with the oracle's output and counts as a rejected round. The Tester's `VERDICT` stays; the oracle decides whether the step's code is accepted. With `enabled` false or unset, the Planner's message is byte-identical to before. The script is a tool, so it also runs by hand from a worktree when `enabled` is false (it says so on stderr).

- **What it checks.** (1) The acceptance command comes from the task spec, never from the worker, and runs in the worktree with an allowlist: `pytest` (also `uv run`, `python -m`), `ruff check|format --check`, `mypy`, `npm|pnpm|yarn` `test|lint|build|typecheck|check|ci|e2e|test:*|lint:*`, `vitest`, `jest`, `tsc`, `eslint`, `playwright test`, `make <target>`, `go test|vet|build`, `cargo test|check|clippy|build`, and `bash <file>.sh`. Commands may be chained with `&&` only: pipes, redirections, substitutions, `rm`, `curl`, `sudo`, `git push` and the like are refused (`command_not_allowed`, nothing runs). API keys, tokens and passwords are removed from the environment of the command. (2) A failing command is retried (`retries`, default 1); if it keeps failing, only the failed test files are rerun on their own (npm/pnpm/yarn test, pytest, vitest, jest) to tell a flaky suite from a real red. (3) Test integrity against the base (`--base`, or the merge-base with `origin/HEAD`, `main`, `master` or `develop`), over commits and uncommitted changes: `test_deleted_without_subject` (a test file deleted while the file it tests stays), `skip_or_xfail_added` (`pytest.mark.skip|xfail`, `it.skip(`, `.only(`, `xit(`, `t.Skip(`, `#[ignore]`...) and `tests_weakened` (more than 20 test lines removed and more than twice as many as added). Deleting a test together with its subject is not a finding. Any finding is a cheat even if the command passes. (4) Secrets in the output (`sk-...`, `ghp_...`, JWTs, `Bearer ...`) are masked.
- **Statuses** (`status` in the JSON): `pass`, `pass_flaky` (passed on a retry or on the isolated files), `fail`, `no_acceptance_command` (no section, or none with commands), `command_not_allowed`, `env_not_runnable` (a runner is not installed: the exit is 127, not a red test) and `dry_run` (`--dry-run`: shows what would run, runs and writes nothing). Exit code 0 only on `pass`/`pass_flaky` with no cheat. `oracle.sh` itself exits 3 if there is no python3 >= 3.8 and 2 on bad usage.
- **Where the result goes.** `verify.json` (status, commands with attempts and the output tail, integrity findings, load, duration, `agent`/`model` of the last `dev` line of `orca-roles.provenance.jsonl`, and `config_sha`, the sha1 of the configuration file) is written to `${ORCA_ROLES_ORACLE_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/orca-roles/oracle}/<task>/verify.json`. It is never written inside the repository, so it cannot end up in a commit and the worker cannot edit its own verdict.
- **Load wait.** Before running, it waits for the 1-minute load average to drop under `maxLoad` times the number of cores, for at most `waitMax` seconds, and then runs anyway (the JSON records the wait and the load). `--no-wait` skips it.
- **Requirements.** python3 >= 3.8 and the standard library only (macOS ships 3.9). `ORCA_ROLES_PYTHON` picks another interpreter. `--task` without `--spec-file` reads the spec from the Orca Run.
- **Enable it.** In `config.json` (or `.orca-roles.json` for one project): `"settings": { "oracle": { "enabled": true } }`. Defaults, all optional: `maxLoad` 0.8, `waitMax` 300 (seconds), `timeout` 600 (seconds per command attempt), `retries` 1. `oracle.sh` looks the settings up in `ORCA_ROLES_CONFIG`, else the worktree's `orca-roles.config.json`, else the merged configuration. `spec_lint.py` (in `bin/oracle/`) lints a spec file: `python3 ~/.orca-roles/bin/oracle/spec_lint.py --file spec.md`.

#### Read-only coordinator check: `loop.sh`

A coordinator that polls Orca wakes the Planner (an expensive model) on every turn even when nothing needs it. `~/.orca-roles/bin/loop.sh` is one read-only cycle that answers "does anything need the Planner?" so the poller wakes it only when `wake` is true.

- **What it reads.** For each recent Run (`--run <id>`, repeatable, or every Run updated in the last `--since-hours`, default 48): `orca orchestration task-list --run`, `worker-list --run --limit 100` and `inbox --limit 500` (the inbox read marks nothing as read), plus `orca terminal show` for a worker that has no workspace. The Orca command is `orca`, or `$ORCA_CLI_COMMAND` when `orca` is not on the PATH.
- **What it never does.** It does not ack, release a worker, send a message, update a task or write anything to Orca. What a full loop would do next is only listed in `would_do` (`worker-release --dispatch <id>` for a verified task whose worker is `reclaimable` or `retained`; `verify <task> in <worktree>` when nothing was run).
- **When it wakes.** An unread `question`, `escalation` or `failed` message; a recently completed task with outcome `succeeded` whose oracle status is not `pass` or `pass_flaky` (`fail`, `cheat`, `command_not_allowed`, `env_not_runnable`, `no_acceptance_command`, `verify_error`); or a task with no worktree to verify (`no_worktree`: the path is gone or the worker has no terminal). If Orca does not answer, that is also a reason.
- **When it runs commands.** Only when `settings.oracle.enabled` is `true`: then, for each completed `succeeded` task that has no `verify.json` yet (or with `--force`), it runs `bin/oracle/verify_task.py --task <id> --run <run>` in the task's worktree, with the same allowlist and the same `timeout`, `maxLoad` and `waitMax` as `oracle.sh`. A cached `verify.json` is not run again, but a cached result other than `pass`/`pass_flaky` still wakes. Otherwise the wrapper adds `--no-verify` by itself and the cycle only reads Orca. `--no-verify` forces that too.
- **Output.** JSON on stdout: `{ts, dry_run: true, wake, reasons, runs}`; each run has `verified` (task, status, seconds, `cached`), `messages` (the unread ones that woke it), `would_do` and its own `reasons`. Exit 0 on every completed cycle (the decision is `wake`), 2 on bad usage, 3 without python3 >= 3.8 (`ORCA_ROLES_PYTHON` picks the interpreter).

```sh
# in the coordinator's poll loop: spend a Planner turn only when the check says so
out="$(~/.orca-roles/bin/loop.sh --since-hours 24)"
if [ "$(jq -r .wake <<<"$out")" = true ]; then
  jq -r '.reasons[]' <<<"$out"   # hand these to the Planner as the reason for waking it
fi
```

### Using other agents

```json
"dev":    { "agent": "codex", "model": "<codex-model>" },
"tester": { "agent": "opencode", "model": "<provider/model>" }
```

The roles receive their instructions the same way as with Claude (the kit types into their terminal when they are ready), so they work with any agent with a terminal interface that can read files and run `orca orchestration`.

For OpenCode use `agent: "opencode"` (see [OpenCode roles](#opencode-roles)), not a `custom` command: OpenCode 2.x's main interface takes no `--model` or `--agent`.

With `agent: "custom"`:

- The `command` runs with `bash -lc`, that is, in a login shell with your profile's PATH (nvm, brew, etc.).
- Placeholders: `{model}` → `model` field; `{prompts}` → the `~/.orca-roles/prompts` folder; `{prompt}` → path of the role's prompt file (useful if the role lives in `~/.orca-roles/roles/`); `{mcp}` → file with the role's MCP servers (empty with `mcp: "all"`); `{scratch}` → the role's scratch folder, created before launching (also in `ORCA_ROLES_SCRATCH`); `{anchor}` → the line that makes the agent ask for its role again after its conversation is cleared, for its system prompt flag (also in `ORCA_ROLES_ANCHOR`; see [Cleaning the workers' context](#cleaning-the-workers-context)). The values are quoted automatically.
- `extraArgs`, `env` and `mcp` do apply, and so do `addDirFlag` (with `extraDirs`) and `trust`. `permissionMode` and `allowedTools` do not: they are Claude Code's. Pass the equivalent in the `command` itself or with `extraArgs`.
- The agent must be able to read `~/.orca-roles/prompts` (and `~/.orca-roles/roles` if you use your own roles) on its own: the kit only passes it the scratch folder and `extraDirs`, and only with `addDirFlag`.
- Accepting the trust dialog and closing the composer's extra session look for Claude Code's texts; with another agent they are not detected, but the startup works the same.

Codex (`agent: "codex"`):

- `permissionMode: "auto"` runs it with `--sandbox workspace-write --ask-for-approval on-request`. The role's scratch folder and each `extraDirs` entry are always passed as `--add-dir` (they are writable only with `workspace-write`).
- Every codex role needs codex >= 0.48 (`--add-dir` is passed in every mode).
- With `settings.trust` `"never"` this override is left out and Codex asks. Otherwise the trust dialog is answered with a single `-c 'projects={"<worktree>" = {trust_level = "trusted"}}'` override: nothing is written to `~/.codex/config.toml`.
- Checked with Codex 0.162 without a session that uses a model: it rejects `--full-auto`, accepts the flags above, and with the `-c projects` override it opens without the trust dialog and writes nothing to its `config.toml`. Whether the `--add-dir` folders are writable in a real session was not measured.

#### OpenCode roles

`agent: "opencode"` runs `opencode mini --agent orca-<role> [--model <model>]` (the main `opencode` interface has neither flag; `mini` has no `--auto`). `extraArgs` are appended. Before it starts, `bin/opencode-prepare.sh` writes `<worktree>/.opencode/agents/orca-<role>.md`, rewritten on every start, and adds `/.opencode/agents/orca-*.md` once to the repo's `info/exclude` (never a tracked `.gitignore`). A worktree outside git is refused. OpenCode takes its directory from `$PWD`, so the kit starts it from the physical path.

- **System prompt.** The Markdown body is the role anchor, the role's common rules (`common`, else the mode's `common-workers.md`) and the role's prompt. The startup message therefore only says that the role is in the system prompt; `/new` is the clear command.
- **Frontmatter.** `description`, `mode: "primary"`, `model` (if the role has one), `steps` and `permissions`, all strings as JSON-quoted YAML.
- **Permissions.** OpenCode applies the last matching rule, and a call that matches none waits for an answer nobody gives in an unattended tab. So the list starts with `allow * *`, then denies: `question` (workers use `orca orchestration ask`), `shell git push*`, and `edit` on the kit's own folders (`prompts`, `roles`, `bin`, `plugin`, `config.json`, `config.default.json`; the scratch folders under the kit stay writable). Then comes `roles.<id>.opencode.permissions`, as written; an item without string `action`/`resource` or with an `effect` other than `allow`, `ask` or `deny` is skipped with a warning.
- **Steps.** `roles.<id>.opencode.steps`, else `settings.flow.maxStepsPerWorker` (applies only to OpenCode roles), else no cap. Not a positive integer: warning and left out.
- **MCP.** The kit's `mcpServers` are not passed: configure MCP servers in OpenCode itself. A role with a non-empty `mcp` list gets one warning at start.
- **Dispatch.** Orca's `orca orchestration worker-start --terminal <handle>` never sees an `opencode mini` tab as ready: its `agent_readiness` stage times out (seen with Orca 1.4.218). When an OpenCode role is active, the Planner's startup message tells it to dispatch that role's tasks with `orca orchestration dispatch --task <task_id> --to <handle> --inject --json` instead, which Orca documents for processes an operator started. The cost: Orca does not supervise those workers (`worker-show`, `worker-stop` and `worker-abandon` do not apply); their `worker_done` reaches the Planner as usual. Checked end to end: Planner on Claude, Dev on OpenCode, task dispatched with `--inject`, `worker_done` received and the oracle passed.
- **Sessions.** Unless `extraArgs` has `--session`, `-s`, `--continue`, `-c` or `--fork` (then the sessions are yours: the kit adds and saves nothing), `agent.sh` starts `mini` with `--session <id>` and saves the id in `<git dir>/orca-roles-opencode-<role>.session`. The id is `ses_orca_<role>_<digits>`, or the `--resume` value when given. When Orca restores the tab after a restart, `launch.sh` reopens the role with its saved id, so the conversation continues. The session is deleted (`opencode session delete`, run in the worktree, cut after 20 s, best effort: one line if it fails) by `close-role.sh` before it closes the tab (so `relaunch-role.sh` too: closing a `mini` tab does not stop a running turn, deleting the session does) and when `launch.sh` replaces a dead or closed tab without memory. After `clean.sh` (`/new`), the kit saves the newest session of the worktree created since `/new` and deletes the old one; if it finds none it says so and still deletes the old one.
- **Checked with one real run** (OpenCode 2.0.25, Orca 1.4.218, a local model, one trivial task): `orca terminal wait --for tui-idle` returns once `mini` is ready (about 10 s after the tab opened), and text sent with `orca terminal send --enter` reaches `mini` and runs; Orca accepts it but warns that it cannot confirm delivery for this agent. The status bar showed the generated agent and its model, the agent file stayed out of `git status`, and the worker edited the file and ran the test. Session ids look like `ses_` followed by 26 letters and digits (`opencode session list`, run in the worktree).
- **`agentIdentity`.** Orca reported none for the `mini` tab right after start, before the first message, and `opencode` once the task had run. A role that has not received its first message yet would look dead, so a live tab still counts as alive for OpenCode roles.
- **Missing model.** `opencode mini --model <missing>` starts, accepts the message and ends the turn without printing any error (only OpenCode's own log says `Model unavailable`), so no screen pattern can detect it. Before sending the role message the kickoff therefore looks the model (without any `#variant`) up in `opencode models`, run in the worktree. OpenCode's service can omit models on the first call after it starts, so a model not found is looked up once more after about 3 seconds. Still missing: the role message is sent anyway, the line `ROLE=FAILED:<model>` goes to `orca-roles.models` and the Planner gets the same "model unavailable" escalation as for the other agents. If `opencode models` cannot be read (failure or timeout, twice), the kickoff only prints that the model could not be checked and tells nobody. The check costs nothing (it calls no model) and applies only to OpenCode roles with a `model`. A `modelError` of the role still works as for `custom` roles.
- `dev-opencode` in `config.default.json` is a disabled example.

```json
"dev-opencode": { "agent": "opencode", "model": "provider/model", "common": "{kit}/prompts/programmer/common-peon.md",
                  "opencode": { "steps": 120, "permissions": [{ "action": "shell", "resource": "rm *", "effect": "ask" }] } }
```

Antigravity (`agy`) has no trust flag and no sandbox that lets it write only in some folders. Example:

```json
"dev": { "agent": "custom", "command": "agy --dangerously-skip-permissions --model {model}", "model": "<model>",
         "addDirFlag": "--add-dir",
         "trust": { "file": "~/.gemini/antigravity-cli/settings.json",
                    "jq": ".trustedWorkspaces = ((.trustedWorkspaces // []) + [$dir] | unique)" } }
```

**Warning:** the only way we measured for `agy` to write without asking is `--dangerously-skip-permissions`, which lets it write anywhere, not only in the worktree (`--mode accept-edits` and `permissions.allow` are alternatives we did not measure); `--add-dir` gives it read access only, and `--sandbox` makes everything read-only. Use it only for roles you accept that for.

### Round log

With `settings.flow.recordRounds: true` (programmer mode), the Planner records every Dev round once it has its verdict, before the next dispatch:

```bash
~/.orca-roles/bin/round.sh dev --step <step> --round <n> --outcome accepted|rejected|oracle-red [--task <task id>]
```

Each call appends one JSON line to `orca-roles.rounds.jsonl` in the repository's git common dir (the main checkout's `.git`), so the data outlives the worktree:
- `ts`, `worktree` (its branch), `step`, `round`, `role`, `task` and `outcome` (`oracle-red` when the oracle is red, whatever the Tester says).
- The `agent` and `model` in effect for that role in this worktree. After a `relaunch-role.sh`, that is the new model.
- `files`, `added` and `removed`: the worktree's uncommitted change against `HEAD`. It accumulates over the set, since nothing is committed per step.

The point is data: which tasks each model gets right on the first round. Read it with `jq -s` (e.g. the acceptance rate per model), alongside the tokens per role that `metrics.sh` reports. The file is local and never leaves the worktree.

### Escalation

Start a worker on a cheaper model and move it to a stronger one only when its work fails a check:

```json
"settings": { "flow": { "escalation": { "dev": { "to": "claude-opus-5-5", "after": 1 } } } }
```

How it works (programmer mode):
1. The Planner runs `round.sh` after each round of the role that writes code, as in [Round log](#round-log). The startup message asks for it as soon as an active role has an escalation, with or without `recordRounds`.
2. When the step reaches `after` rejected or oracle-red rounds, `round.sh` relaunches the role on `to` with `relaunch-role.sh`. That script checks the model first, and the role reopens with a new tab and handle.
3. On the step's accepted round, `round.sh` relaunches the role back on the model it had. The model in effect before escalating is kept in `<gitdir>/orca-roles.escalation`.
4. The Planner tells you in one line and uses the new handle. The rejected rounds still count toward the step's limit (`roundCap`, 3 by default).

Things to know:
- **Same agent only.** `to` must be a model of the role's own agent: for an OpenCode role, a model of `opencode models`. Moving a step from an OpenCode role to a Claude one is not covered.
- **Every relaunch is a fresh start.** The role reads its prompt again, and the step's context goes with the old tab.
- **An abandoned step keeps the role escalated.** A step closed without an accepted round leaves the role on `to` until some step is accepted.

Checked with a real team in a toy repo: a rejected round relaunched Dev from Sonnet on Opus, and the accepted round brought it back. Each time the new tab opened in that worktree and its start was recorded in the provenance. Run `round.sh` from the worktree's own terminal, as the Planner does: launched from a terminal of another worktree, the relaunched tab opens in that other worktree.

Why on a failed check and not by guessing the difficulty up front: in published evaluations, a frontier model asked to predict which coding steps are hard flagged few of them. Off-the-shelf routers did no better than a fixed tier. What did work was escalating on verified failure, or a small classifier trained on your own outcomes. The [Round log](#round-log) collects the data for that.

### Coordinator above the worktrees

To run several features at once, each in its own worktree with its own team, start a coordinator in an Orca terminal (for example in the project's main checkout):

```bash
~/.orca-roles/bin/coordinator.sh            # Claude Code with the Planner's model and permission mode; --model <m> to change it
```

It follows [`prompts/coordinator.md`](prompts/coordinator.md) and Orca's orchestration guide:
1. It splits what you ask for into features, one worktree each, and waits for your yes.
2. It creates one Run for the objective.
3. Per feature, it creates the task first and marks the worktree as coordinated (a file `<git common dir>/orca-roles.coordinated/<worktree name>` in the main checkout, holding the coordinator's Run id). Then it creates the worktree (`orca worktree create --setup run`, so the kit opens the team). The marker makes the kit tell the Planner, in its startup message, to wait for the coordinator's task instead of planning with you; the kit removes it when it starts the Planner, and keeps the Run id beside the worktree's state (`<git dir>/orca-roles.coordinator`). When the Planner has its role and its tab shows it waiting, the coordinator gives the Planner the feature as a supervised task with `orca orchestration worker-start --task <id> --terminal <planner> --worktree id:<worktree id>`. It does not use `worker-start --worktree new-*`, which would start a second agent beside the Planner.
4. Each Planner works as usual with its own team, in its own Run. What it would ask you, it asks the coordinator with `ask`: the plan, doubts, commits, anything that leaves the worktree. It ends with one `worker_done` and a report. Outside a dispatch (`ask` and `worker_done` need one), for example when the coordinator typed the task into its tab, its startup message, in every mode, tells it to write to the coordinator's Run with `orca orchestration send --to run:<id>` instead (`question`, or `status` for the end), never in its tab; the coordinator's `reply` reaches the Planner's own Run (the "Working under a coordinator" section of the Planners' prompts). The coordinator answers what it can, asks you the rest, and reports each feature to you.

Requirements: Orca must allow nested workers 2 deep (Settings → Orchestration → "Nested worker depth", default 1), because each Planner dispatches to its workers one level below the coordinator. The project must also start the kit in new worktrees (`roles-yaml`). Every worktree opens a whole team, so keep the number of open worktrees to what you need. Without a coordinator nothing changes: a Planner that gets no dispatch talks to you in its tab as before.

Checked end to end with two worktrees of a toy repo, each with Planner and Dev:
- The kit opened both teams and `worker-start --terminal` gave each Planner its feature.
- Both Planners asked for plan approval with `ask`.
- With the nested depth at 1, both stopped with `nested_worker_depth_exceeded` and asked what to do, instead of writing the code. At 2, each dispatched its Dev.
- Both sent `worker_done` with their report, and `worker-release` left the Planners' tabs open.
- Then `coordinator.sh` itself (Sonnet) ran the same two features from one request: it created the Run and both worktrees, waited for the teams, dispatched each Planner, checked both results in the worktrees and released both dispatches, in about two and a half minutes.
- On a real repository, before the marker existed, both Planners started planning on their own from the branch name and the linked issue, and each opened a question dialog in its tab. Orca refused both dispatches with `agent_prompt_blocked` while the dialogs were open; `terminal wait --for tui-idle` had already returned, because it is also satisfied with a dialog open. Hence the marker, and the coordinator reading the Planner's tab before it dispatches.
- On the same repository, a coordinator that fell back to typing the tasks into the Planners' tabs then waited by reading those tabs: a Planner's question went unanswered for hours, because it was asked while the coordinator waited for the user and its watcher only looked at the newest turn. Hence the coordinator's Run in the marker and the Planner's messages to it.

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

The E2E-Tester still needs the `playwright` server, which is a local process (`~/.orca-roles/pw/node_modules/.bin/playwright-mcp`): it works in any agent that can start it.

### Placeholders in `mcpServers`

In the `args`, `env` and `url` of any server they are expanded when each role starts:

| Placeholder | Value |
|---|---|
| `{worktree}` | Absolute path of the worktree |
| `{project}` | Name of the main repo's folder (not the worktree's) |
| `{evidenceDir}` | `params.evidenceDir` of the role (or of the E2E-Tester, or `qa-evidence`) |
| `{browserState}` | `~/.orca-roles/browser/{project}/default.json`, the `default` identity session saved by `browser-login.sh` (created empty if missing) |
| `{kit}`, `{home}` | `~/.orca-roles` and your `$HOME` |

The default `playwright` server uses them like this:

```json
"playwright": { "command": "{kit}/pw/node_modules/.bin/playwright-mcp",
                "args": ["--browser", "chromium", "--headless", "--isolated",
                         "--storage-state", "{browserState}", "--output-dir", "{worktree}/{evidenceDir}"],
                "env": { "PLAYWRIGHT_BROWSERS_PATH": "{kit}/browsers" } }
```

To see the browser in a project, remove `--headless` in its `.orca-roles.json` (lists are replaced whole, so copy the other args).

### Per-project configuration

A `.orca-roles.json` at a repo's root is merged on top of your global configuration for that project only. It is looked up at the worktree root and, if missing, at the main checkout root, so it works even if you do not commit it. For example, for a library without an API:

```json
{ "roles": { "e2e-tester": { "enabled": false }, "deployer": { "enabled": false } } }
```

Objects are merged field by field; lists are replaced whole.

### Exceptions in the setup script

Without creating any file, you can add options to the `launch.sh` line in the project's setup script (Settings → Repository, or the `orca.yaml` of `roles-yaml`; `roles-yaml --mode <mode>` writes `--mode` there for you). They are applied on top of `config.json` and `.orca-roles.json`:

```
$HOME/.orca-roles/bin/launch.sh --disable e2e-tester,deployer
```

| Option | What it does |
|---|---|
| `--only a,b` | Only those roles; the `planner` always runs. |
| `--enable a,b` | Enables roles disabled in the configuration. |
| `--disable a,b` | Disables roles. The `planner` cannot be disabled. |
| `--set path=value` | Changes any configuration key. The path uses dots and the value is read as JSON if it is JSON (`true`, `10`, `["x"]`) and as text otherwise. |
| `--mode <mode>` | The team's mode (`programmer`, `pr-reviewer`, `academic-research`); beats `settings.mode` and `.orca-roles.json`. Rejected if the worktree's team is open in another mode. See [Modes](#modes). |
| `--reset` | Forgets the worktree's saved exceptions first, so only the options of this run apply (only with `roles`). |
| `--status` | Shows the team and exits; it changes nothing in the worktree or Orca and opens nothing. First line `Mode: <mode>`, then one tab-separated line per role: `<Title>`, handle, state (`alive`, `no tab`, `agent gone`, `orphaned`), configured model (`-` if none) and model in use from `orca-roles.models` (`FAILED:<model>` as recorded, `-` if not recorded), then `<agent>@<CLI version>` and the first 7 characters of the prompt's sha1, from the role's last [provenance](#metrics-and-provenance) line (`-` and `-` if none). Without a launched team: `No team launched in this worktree.` |

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
| `flow.roundCap` | Optional positive integer (programmer mode; the other modes have no review rounds): how many rejected rounds a step may pile up before the Planner stops and checks with you. Unset: the 3 written in the Planner's prompt. When set, the Planner's startup message carries a sentence that replaces that 3. Anything that is not a positive integer is ignored with a warning. |
| `flow.maxStepsPerWorker` | Optional positive integer: the default `steps` (cap on the agent's steps) of an OpenCode role; `roles.<id>.opencode.steps` wins. It only applies to roles with `agent: "opencode"`. Unset: no cap. Anything that is not a positive integer is ignored with a warning. |
| `flow.workerReportBody` | `"full"` (default, also when unset) or `"short"`. With `"short"` the body of a worker's `worker_done` is at most about 8 lines (outcome, files changed, how it was verified and the result, open issues) and the full detail goes to a file in the worker's `scratchDir` whose absolute path the body names; the Planner is told so and reads that file when it needs it. Questions and escalations stay full sentences. The worker's startup message carries the override, so it applies to the role message `clean.sh --msg` prints too. Any other value is ignored with a warning. |
| `flow.recordRounds` | Optional, `true` to turn it on (programmer mode): after each Dev round, once it has the verdict, the Planner runs `bin/round.sh`, which appends one line to `orca-roles.rounds.jsonl` in the main checkout's `.git`. See [Round log](#round-log). Unset or anything but `true`: the Planner's startup message is unchanged. |
| `flow.escalation` | Optional (programmer mode): `{"<role>": {"to": "<model>", "after": N}}`. After N rejected rounds of a step (default 1), `round.sh` relaunches that role on `to`, and brings it back to its own model on the step's accepted round. See [Escalation](#escalation). An invalid value, or one for the Planner, is ignored with a warning. |
| `oracle` | Optional executable oracle for Dev's work (programmer mode): `{"enabled": false, "maxLoad": 0.8, "waitMax": 300, "timeout": 600, "retries": 1}`. Off by default; when `enabled` is `true` the Planner's startup message gets a sentence telling it to require an acceptance command in each Dev spec and to run `bin/oracle.sh` after each Dev report. See [Optional oracle](#optional-oracle). |
| `trust` | Whether the kit marks the worktree as trusted for the agents: `"worktree"` (marks it in `~/.claude.json`, passes Codex its trust override, and accepts Claude Code's trust dialog itself) or `"never"` (the agents show the dialog and each tab waits for you; see [Trust of the folder](#trust-of-the-folder)). Unset: `"worktree"`. Any other value warns and counts as `"never"`. |
| `mode` | The team's mode: `programmer` (default), `pr-reviewer` or `academic-research`. See [Modes](#modes). |
| `phase` | academic-research only: the phase (`experiment` by default or `writing`). Changed by the Planner with `phase.sh`, not by hand. |
| `language` | The language the Planner replies to you in. `"auto"` (default): the language you write in. Any other value (`"Spanish"`, `"English"`...): always that one. The prompts are in English either way. The workers always write in English (their repo artifacts follow the repo's language): for Claude workers the kit passes `--settings '{"language":"english"}'`, overriding Claude Code's own `language` setting, and every worker also gets the rule in its role anchor (the only channel for Codex and custom agents, whose own language settings are not overridden). A `--settings` in a role's `extraArgs` replaces the kit's one (claude does not merge them), so include `"language":"english"` in it. |

## Files

```
orca-role-hook/                  # this repo → installed into ~/.orca-roles/
├── install.sh
├── VERSION                      # the kit's version (same as plugin/.claude-plugin/plugin.json)
├── config.default.json          # default configuration (your copy: ~/.orca-roles/config.json)
├── bin/
│   ├── launch.sh                # setup script: opens the tabs and saves their handles
│   ├── agent.sh                 # launches a role's agent according to the configuration
│   ├── kickoff.sh               # sends each agent its role, passes the Jira ticket and closes the extra agent
│   ├── clean.sh                 # cleans the workers' context and resends their role
│   ├── checkpoint.sh            # records the tree under refs/orca-roles/checkpoints/ (the Planner's briefs diff rounds against it)
│   ├── crosscheck.sh            # throwaway copies of a ref (with the worktree's dependencies linked) to run tests on other code, and patches between them
│   ├── close-role.sh            # closes a role's tab in the current workspace
│   ├── relaunch-role.sh         # relaunches one role with another model
│   ├── forget-trust.sh          # removes the trust the kit gave to worktrees in ~/.claude.json
│   ├── models.sh                # lists a role's candidate models and tests them
│   ├── metrics.sh               # token usage per role and session (read-only), from Claude Code's session files
│   ├── oracle.sh                # optional oracle: runs a task spec's acceptance command and checks the tests were not cheated
│   ├── oracle/                  # its python3 parts (verify_task.py, allow.py, spec_lint.py, loop.py)
│   ├── loop.sh                  # read-only coordinator check: says whether anything needs the Planner (reads Orca, never writes)
│   ├── review-skill.sh          # installs and locates the pr-reviewer mode's review skill
│   ├── phase.sh                 # switches an academic-research team's phase
│   ├── academic-scaffold.sh     # creates the paper repository's folders and .gitignore lines
│   ├── scholar.sh               # scholarly search, BibTeX, verification and open-access PDFs
│   ├── scholar-arxiv.awk        # scholar.sh parser (arXiv)
│   ├── scholar-norm.jq          # scholar.sh parser (result normalization)
│   ├── scholar-bibfix.jq        # scholar.sh parser (BibTeX fixes)
│   ├── browser-login.sh         # saves your application session for the E2E-Tester
│   ├── e2e-browser.sh           # checks and installs the E2E browser stack (pinned Playwright packages and Chromium) and checks saved sessions
│   ├── e2e-run.sh               # runs an E2E flow (a Playwright script) on the pinned stack and writes its evidence
│   ├── new-role.sh              # wizard to create roles (the new-role command)
│   ├── lib.sh                   # shared functions
│   ├── orca-yaml.sh             # registers the kit in a project with a local orca.yaml (the roles-yaml command)
│   └── apply-hooks.sh           # explains at install time how to register the kit in each project
├── pw/                          # package.json and package-lock.json pinning @playwright/mcp and @playwright/test, and e2e.config.js, the Playwright config e2e-run.sh uses (installed in ~/.orca-roles/pw)
├── .claude-plugin/marketplace.json  # makes the repo a Claude Code marketplace (/plugin install orca-roles@orca-role-hook)
├── plugin/                      # Claude Code plugin the Planner loads
│   └── skills/team/SKILL.md     # guide to the kit: installation, configuration, exceptions, new agents
├── prompts/
│   ├── programmer/
│   ├── pr-reviewer/
│   └── academic-research/       # each mode's folder holds:
│       ├── common-workers.md    # rules common to the mode's workers
│       ├── reports.md           # written-report rules, read by a worker only when a task asks for a report
│       └── <role>.md            # each role's instructions (with its review method, if it has one)
├── tests/
│   └── smoke.sh                 # tests of configuration, inheritance, merge, update and the scripts
└── .github/workflows/ci.yml     # shellcheck + smoke on every push to main and every PR
```

To change a role's behavior, edit `prompts/<mode>/<role>.md` in the repo and run the installer again. Whatever you edit directly in `~/.orca-roles/prompts/` is overwritten on update; your `config.json` and your roles in `~/.orca-roles/roles/` are not.

Inside each worktree:

- `research/`, `qa-evidence/` and `qa-e2e/`: the Researcher's work, the E2E-Tester's evidence (screenshots, `report.json`, `result.json`) and its flows (`qa-e2e/<flow>/`). They are ignored locally in `.git/info/exclude`, without touching your `.gitignore`; never committed.
- `refs/orca-roles/checkpoints/<worktree id>/<step>-c<n>`: the Planner's per-round snapshots of the tree (commits kept out of every branch, made without touching HEAD, the index or the files); `checkpoint.sh --list` shows them and `--clear <step>` deletes a step's and `--clear-all` every one of the worktree's (after the set's last commit). Each checkpoint's message records a creation sequence number, which the diff hints use to find the previous step's last checkpoint. Files marked assume-unchanged or skip-worktree are recorded as in the index, not as in the working tree, and `checkpoint.sh` warns about them. Renaming a worktree's folder, or moving the main checkout (its git dir moves with it), changes its id, so checkpoints taken before no longer show in `--list` or `--clear`; remove them with `git update-ref -d <ref>` (`git for-each-ref refs/orca-roles/checkpoints` lists them). Moving a linked worktree to another parent folder with `git worktree move` keeps them.
- `DEPLOYMENT.md`: the Deployer's guide. It is not committed unless you ask.
- In the worktree's git dir (`git rev-parse --git-dir`): `orca-roles.config.json` (effective configuration used), `orca-roles.overrides.json` (setup script exceptions, if any), `orca-roles.pty` (each role's terminal identity, to recognize the tabs Orca restores after a restart), `orca-roles.lock` (a directory while a launch runs, holding its pid), `orca-roles.kicked` (the handle each role had when it got its role message), `orca-roles.kickoff.d/` (one file per running kickoff, named by its pid, with the roles it will kick; removed when it ends), `orca-roles.wtid` (the worktree id of the last launch), `orca-roles.legacy-note` (the old-mode note of the last launch, which the Planner relays; absent when there is none), `orca-roles.notes/<role>.md` (a role's instructions for this worktree only), `orca-roles-mcp-<role>.json` (MCP servers each role received), `orca-roles.env` (handles), `orca-roles.preexisting.json`, `orca-roles.composer-seen.json` and `orca-roles.setup-context` (tabs seen when the worktree was created, and whether Orca's setup script started the kit, to recognize the composer's session), `orca-roles-launch.log` and `orca-roles-kickoff.log` (startup), `orca-<service>.log` and `orca-<service>.pid` (the Deployer's local services).
- Outside the worktree: `~/.orca-roles/browser/<project>/<identity>.json`, the browser sessions for the E2E-Tester and its flows; `~/.orca-roles/pw/` and `~/.orca-roles/browsers/`, the pinned E2E stack and its Chromium.
- Outside the worktree too: each role's scratch folder, `~/.orca-roles/tmp/<project>-<hash of the git dir>/<role>/`, one per worktree and role, fixed (the same path every time). Agents put their temporary copies there (the Tester's mutation copy, the Auditor's experiments, the Researcher's earlier versions) and reuse it; they never delete anything in it, so Claude Code does not ask for permission on every `rm`, and the kit never empties it either. `copy/` (the copy of the current tree) stays current because every use runs `rsync -a --delete` into it; copies made by `crosscheck.sh tree` (a ref's files, the worktree's ignored entries such as dependencies linked rather than copied, caches left out) are replaced by the script itself on their next use; earlier versions go in `rev-<full commit hash>/` (one per commit, reused if it exists) and the Researcher's temporaries have fixed names per task, so those accumulate slowly. When a worktree is removed, its folder stays orphaned in `~/.orca-roles/tmp/`; remove it by hand when you want the space back, for example `rm -rf ~/.orca-roles/tmp/<project>-<hash>`. The role receives its path as the `scratchDir` parameter in its startup message, and Claude and Codex agents get it with `--add-dir` (`custom` agents through `{scratch}`/`ORCA_ROLES_SCRATCH` and `addDirFlag`). It is outside the worktree because jest, vitest and eslint collect copies of the project that live inside it, and none of them honors `.gitignore` or `.git/info/exclude`.
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
6. **E2E-Tester**: `~/.orca-roles/bin/e2e-browser.sh install` inside WSL; `e2e-browser.sh check` then prints the `sudo` command for any system libraries Chromium still needs.

**Orca's CLI has another name.** In WSL terminals, Orca does not install `orca` but a launcher whose name is given by `$ORCA_CLI_COMMAND` (`orca-ide` in Orca 1.4.219), which calls `orca.exe` on Windows. The kit detects it and creates the `~/.orca-roles/shim/orca` wrapper, which it prepends to the PATH of its scripts and of the agents; the prompts and the permissions (`Bash(orca orchestration:*)`) keep working unchanged. That is why the CLI is only available in terminals opened by Orca: the kit's commands (`roles`, `clean.sh`, the installer) must be run from one of them. So you can also type `orca ...` yourself in those terminals, the installer adds to your `~/.bashrc` an `orca` alias to `$ORCA_CLI_COMMAND`, which only applies when that variable is set and there is no real `orca`. Do not install the `orca` package apt suggests: it is GNOME's screen reader.

The installer adds the `roles`, `new-role` and `roles-yaml` commands to `~/.zshrc` (zsh), `~/.bashrc` (bash on Linux), `~/.bash_profile` (bash on macOS) or `~/.profile` (other shells).

## Requirements

- Orca with Orchestration enabled (Settings > Experimental).
- `jq` (macOS: `brew install jq`; Ubuntu/Debian: `sudo apt install jq`). It is essential: the installer and the kit fail with a clear message if it is missing.
- Claude Code (`claude`) with `--permission-mode auto` available. The installer checks it and warns you if your version does not offer it; in that case update Claude Code or change `permissionMode` in `config.json`. Checked with 2.1.x.
- The CLIs of any other agent you configure.
- `curl` and `tar` (they come with macOS and Ubuntu), Node (`npx`, for Playwright). For the E2E-Tester, the kit's pinned Chromium: `~/.orca-roles/bin/e2e-browser.sh install` (npm is needed; on Ubuntu, `e2e-browser.sh check` prints the `sudo` command for the system libraries it needs, which the kit never runs).

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
| A role never answers its first message | Its `model` may not exist: after the role message the kickoff compares the screen with what it showed before and, if a new model error appeared (Claude Code's "There's an issue with the selected model", Codex's "does not exist" API error, or the custom agent's `modelError`; for OpenCode roles the model is looked up in `opencode models` before the message is sent), records `ROLE=FAILED:<model>` in `orca-roles.models` (git dir) and sends the Planner a "model unavailable" escalation; the Planner asks you whether you fix it yourself or want it to. Nothing is switched and `config.json` is never changed: set `roles.<id>.model`, close the tab with `close-role.sh <id>` and run `roles`, or let the Planner run `relaunch-role.sh <id> --model <m>`. In a very small pane the check can miss an error (the kit reads only what the tab shows): the role's first answer tells you. Only roles with a `model` are checked |
| Which models a role can use | `~/.orca-roles/bin/models.sh <role> --check` ([Models of a role](#models-of-a-role)) |
| An agent starts with another model or MCP | `orca-roles.config.json` in the worktree's git dir shows the configuration that was used, and `orca-roles-launch.log` the exceptions applied |
| A role does not appear even though `enabled` is `true` | The worktree's saved exceptions: `orca-roles.overrides.json` in its git dir. Drop them with `roles --reset` |
| `worker-start` fails with `terminal_handle_stale` | A role's tab changed (Orca restarted or lost the window). Run `roles` in a terminal of the worktree: the Planner gets the new handles by a "Role handles changed" message |
| The Planner is not notified when workers finish | A message batch it read but did not acknowledge: Orca types no notice while one is open. `orca orchestration check --peek --json` from the Planner's tab shows the unread messages; ask the Planner to read and acknowledge its messages (`check --ack <delivery_id> --json` until `count` is 0) |
| The Planner replies in another language | `settings.language` (or a `--set settings.language=...` in the setup script); with `"auto"` it replies in the language you write in |
| An agent asks for permissions | That it is in auto mode (`Shift+Tab` shows the current mode) |
| A tab stays on Claude Code's "Do you trust the files in this folder?" dialog and never gets its role | The kit marks the worktree as trusted in `~/.claude.json` before starting the agents (`orca-roles-launch.log` says "Marked ... as trusted") and presses Enter if the dialog still shows (with `settings.trust: "never"`, the default in pr-reviewer, it does neither: answer the dialog yourself, or run `roles` afterwards to send the role). If a tab is stuck anyway, answer the dialog once and run `roles`; and tell us the exact text it showed |
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
| The E2E browser is missing, the E2E-Tester's browser tools fail, or Playwright says `Chromium distribution 'chrome' is not found` or reports a version mismatch | `~/.orca-roles/bin/e2e-browser.sh check` says what is missing; then `e2e-browser.sh install` (the Planner has the Deployer run it after your yes), then reopen the E2E-Tester's tab (`close-role.sh e2e-tester`, then `roles`) so its Playwright MCP connects |
| The E2E-Tester asks for a login, or the session expired | `~/.orca-roles/bin/e2e-browser.sh session <url> --as <identity>` says why (`missing`, `no-session-for-host`, `expired`, `unknown`); sign in again with `~/.orca-roles/bin/browser-login.sh <url> --as <identity>` (omit `--as` for `default`). The session is read when a browser context starts: no cleaning needed |
| The worktree's E2E-Tester still starts `npx @playwright/mcp@latest` | A saved override or your own config has a `mcpServers.playwright` that was not migrated to the kit's pinned stack: drop the override with `roles --reset`, or edit the entry in your configuration |
| `e2e-run.sh` says `<e2eDir>/node_modules` is a real file or folder | Remove it (never `npm install` inside `qa-e2e/`): the kit links its own pinned packages there |
| `e2e-run.sh` does not find the flow | The flow is a folder `<e2eDir>/<flow>/` of the worktree (`qa-e2e/` by default) with at least one `*.flow.ts` or `*.flow.js` |
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
