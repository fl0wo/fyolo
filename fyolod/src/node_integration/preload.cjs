// fyolod puts this file in NODE_OPTIONS (--require) for every session it spawns, so
// it runs at the start of every Node process in a fyolo terminal. Outside Vitest it
// must cost nothing: one regex test of the entry script, then return.
//
// It is CommonJS loaded with --require, not --import, because every Node version
// parses --require. A NODE_OPTIONS flag an older Node doesn't know would stop every
// node process in the session from starting.
'use strict';

const entry = process.argv[1] || '';

// Vitest's own CLI entry, reached directly or through the node_modules/.bin link.
// Pool workers run vitest/dist/workers/* and never match, so they stay untouched.
if (process.env.FYOLOD_SOCK && /[\\/]vitest[\\/]vitest\.mjs$|[\\/]\.bin[\\/]vitest$/.test(entry)) {
  try {
    const nodeModule = require('node:module');
    const { pathToFileURL } = require('node:url');
    const path = require('node:path');
    // module.register exists from Node 20.6 / 18.19. Older Node runs Vitest
    // uncaptured, never broken.
    if (typeof nodeModule.register === 'function') {
      nodeModule.register(pathToFileURL(path.join(__dirname, 'hooks.mjs')).href);
    }
  } catch {
    // Capture is best effort. The user's test run must never see an error from it.
  }
}
