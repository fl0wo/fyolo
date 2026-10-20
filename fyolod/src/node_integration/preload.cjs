// fyolod puts this file in NODE_OPTIONS (--require) for every session it spawns, so
// it runs at the start of every Node process in a fyolo terminal. Outside a test
// runner it must cost nothing: one regex test of the entry script, then return.
//
// It is CommonJS loaded with --require, not --import, because every Node version
// parses --require. A NODE_OPTIONS flag an older Node doesn't know would stop every
// node process in the session from starting.
'use strict';

// Each runner's own CLI entry, reached directly or through a node_modules/.bin
// link. Vitest's pool workers and Playwright's test workers run other entry files
// and never match, so they stay untouched. So does playwright-core's CLI, which
// automation scripts use without the test runner.
const RUNNER =
  /[\\/](?:(vitest[\\/]vitest\.mjs|\.bin[\\/]vitest)|@playwright[\\/]test[\\/]cli\.js|playwright[\\/]cli\.js|\.bin[\\/]playwright)$/;

const match = process.env.FYOLOD_SOCK ? RUNNER.exec(process.argv[1] || '') : null;

if (match) {
  try {
    const path = require('node:path');
    const runner = match[1] ? 'vitest' : 'playwright';
    // Switched off in fyolo's settings since this session started (see
    // fyolod/src/test_runners.rs). Checked only once the process is a runner.
    if (!require('node:fs').existsSync(path.join(__dirname, `${runner}.off`))) {
      if (runner === 'vitest') attachVitest(path);
      else attachPlaywright(path);
    }
  } catch {
    // Capture is best effort. The user's test run must never see an error from it.
  }
}

function attachVitest(path) {
  const nodeModule = require('node:module');
  // module.register exists from Node 20.6 / 18.19. Older Node runs Vitest
  // uncaptured, never broken.
  if (typeof nodeModule.register === 'function') {
    nodeModule.register(require('node:url').pathToFileURL(path.join(__dirname, 'hooks.mjs')).href);
  }
}

function attachPlaywright(path) {
  const args = process.argv.slice(2);
  // `test` only: not install, show-report or merge-reports. UI mode, watch mode and
  // --list show their own results and leave no run worth keeping.
  if (args[0] !== 'test' || process.env.PWTEST_WATCH) return;
  if (args.some((argument) => argument === '--list' || argument === '--ui' || argument.startsWith('--ui-'))) return;
  // Playwright's createReporters appends the reporter PW_TEST_REPORTER names after
  // the configured ones, a CLI --reporter included (1.40 through 1.64). It is one
  // slot: a value the user set wins, and that run goes unrecorded.
  if (!process.env.PW_TEST_REPORTER) {
    process.env.PW_TEST_REPORTER = path.join(__dirname, 'playwright-reporter.cjs');
  }
}
