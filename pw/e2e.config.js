const { defineConfig } = require('@playwright/test');
const path = require('path');
const flowDir = path.resolve(process.env.E2E_FLOW_DIR || '.');
const evid = path.resolve(process.env.E2E_EVIDENCE_DIR || path.join(flowDir, 'out'));
module.exports = defineConfig({
  testDir: flowDir,
  testMatch: /.*\.flow\.(ts|js)$/,
  outputDir: path.join(evid, 'test-results'),
  timeout: Number(process.env.E2E_TIMEOUT_MS || 60000),
  workers: 1,
  reporter: [['list'], ['json', { outputFile: path.join(evid, 'report.json') }]],
  use: { channel: 'chromium', headless: true, storageState: process.env.E2E_STORAGE_STATE || undefined },
});
