#!/usr/bin/env node
// Wakes a tab that Orca keeps asleep after a restart (it is not in 'orca terminal list' and has no handle): Orca resumes its session itself.
// It is a .cjs file so that Node does not look for a package.json above it (on WSL that search fails at the \\wsl.localhost root).
// It uses an internal call of the Orca app (terminal.reveal, through its runtime client) because the CLI has no command for it (see BACKLOG.md).
// Usage: wake-tab.cjs <runtime-client.js> <worktreeId> <tabId> <leafId>; run with Orca's binary in node mode (ELECTRON_RUN_AS_NODE=1).
'use strict';

const args = process.argv.slice(2);
if (args.length !== 4) {
  console.error('usage: wake-tab.cjs <runtime-client.js> <worktreeId> <tabId> <leafId>');
  process.exit(1);
}
const [clientPath, worktreeId, tabId, leafId] = args;

(async () => {
  try {
    const { RuntimeClient, getDefaultUserDataPath } = require(clientPath);
    const client = new RuntimeClient(getDefaultUserDataPath(), undefined, null, null);
    const result = await client.call('terminal.reveal', { worktreeId, tabId, leafId });
    if (result && result.result && result.result.reveal && result.result.reveal.navigated === true) process.exit(0);
    console.error('Orca did not wake the tab');
    process.exit(1);
  } catch (e) {
    console.error(`${(e && e.code) || 'error'} ${(e && e.message) || e}`.replace(/\s*\n\s*/g, ' '));
    process.exit(1);
  }
})();
