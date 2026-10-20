// fyolo's Playwright Test reporter, loaded by Playwright from PW_TEST_REPORTER (see
// preload.cjs). It reports each run to the session's fyolod, as the Vitest reporter
// does, through the public reporter API, which has not changed since 1.40.
//
// It never writes to stdout or stderr, and every failure is silent. The user's
// terminal output must be byte-identical with and without it.
'use strict';

const path = require('node:path');
const { randomUUID } = require('node:crypto');
const {
  Channel,
  plain,
  repositoryRoot,
  packageName,
  sessionFields,
  PROGRESS_INTERVAL_MS,
  MAX_FAILURES,
  MAX_TESTS,
} = require('./channel.cjs');

// A test's verdict once its retries are done. Flaky (passed on a retry) is passed.
function verdict(test) {
  const outcome = test.outcome();
  return outcome === 'unexpected' ? 'failed' : outcome === 'skipped' ? 'skipped' : 'passed';
}

// onTestEnd fires once per attempt; only the attempt that settles the test counts.
function settles(test, result) {
  return (
    result.status === 'skipped' ||
    result.status === 'interrupted' ||
    test.outcome() !== 'unexpected' ||
    result.retry >= test.retries
  );
}

// Spec files are counted per project: the same file in chromium and firefox is two.
function fileKey(test) {
  return `${test.parent?.project()?.name ?? ''}\0${test.location.file}`;
}

class FyoloPlaywrightReporter {
  // Playwright adds its line reporter when no configured reporter prints. Saying no
  // keeps that decision exactly what it would be without this reporter.
  printsToStdio() {
    return false;
  }

  // Global setup can fail before onBegin, so every hook starts the run if it isn't.
  start(config) {
    if (this.run) return;
    const directory = config?.configFile ? path.dirname(config.configFile) : (config?.rootDir ?? process.cwd());
    this.run = randomUUID();
    this.startedAt = Date.now();
    this.root = repositoryRoot(directory);
    this.package = packageName(directory);
    this.channel = new Channel('fyolo-playwright');
    this.counts = { passed: 0, failed: 0, skipped: 0 };
    this.left = new Map();
    this.filesTotal = 0;
    this.filesDone = 0;
    this.errors = [];
  }

  onBegin(config, suite) {
    try {
      this.start(config);
      this.suite = suite;
      this.testDirs = config.projects?.map((project) => project.testDir).filter(Boolean) ?? [];
      for (const test of suite.allTests()) {
        const key = fileKey(test);
        this.left.set(key, (this.left.get(key) ?? 0) + 1);
      }
      this.filesTotal = this.left.size;
      this.report();
      this.timer = setInterval(() => this.flushProgress(), PROGRESS_INTERVAL_MS);
      this.timer.unref();
    } catch {}
  }

  onTestEnd(test, result) {
    try {
      // 1.40 ends an interrupted run as `failed`; the attempts still say so.
      if (result.status === 'interrupted') this.interrupted = true;
      if (!settles(test, result)) return;
      this.counts[verdict(test)] += 1;
      const key = fileKey(test);
      const left = (this.left.get(key) ?? 1) - 1;
      this.left.set(key, left);
      if (left === 0) this.filesDone += 1;
      this.dirty = true;
    } catch {}
  }

  onError(error) {
    try {
      this.start(undefined);
      this.errors.push(error);
      this.dirty = true;
    } catch {}
  }

  flushProgress() {
    if (!this.dirty) return;
    this.dirty = false;
    this.report();
  }

  async onEnd(result) {
    try {
      this.start(undefined);
      clearInterval(this.timer);
      const detail = this.detail();
      this.counts = detail.counts;
      this.filesDone = detail.files.length;
      // A spec file that failed to load is known only now.
      this.filesTotal = Math.max(this.filesTotal, this.filesDone);
      const state =
        result.status === 'interrupted' || this.interrupted
          ? 'interrupted'
          : result.status === 'passed'
            ? 'passed'
            : 'failed';
      await this.report({ state, detail: { files: detail.files, failures: detail.failures } }, true);
    } catch {}
  }

  report(extra = {}, final = false) {
    if (!this.channel) return Promise.resolve();
    return this.channel[final ? 'sendFinal' : 'send']({
      op: 'report_test_run',
      runner: 'playwright',
      id: this.run,
      root: this.root,
      package: this.package,
      ...sessionFields(),
      argv: process.argv.slice(2),
      started_at: this.startedAt,
      duration_ms: Date.now() - this.startedAt,
      files_total: this.filesTotal,
      files_done: this.filesDone,
      counts: this.counts,
      state: 'running',
      ...extra,
    });
  }

  detail() {
    const counts = { passed: 0, failed: 0, skipped: 0 };
    const files = new Map();
    const failures = [];
    let testsKept = 0;
    const relative = (file) => (file ? path.relative(this.root, file) : undefined);
    const failure = (kind, file, test, error) => {
      if (failures.length >= MAX_FAILURES) return;
      failures.push({
        kind,
        file,
        test,
        // Playwright puts Expected/Received in the message; it has no separate diff.
        message: plain(error?.message ?? error?.value ?? String(error)),
        location: error?.location?.file ? `${relative(error.location.file)}:${error.location.line}` : undefined,
      });
    };

    for (const test of this.suite?.allTests() ?? []) {
      const project = test.parent?.project()?.name || undefined;
      const file = relative(test.location.file);
      const key = `${project ?? ''}\0${file}`;
      let entry = files.get(key);
      if (!entry) {
        entry = { path: file, project, state: 'skipped', duration_ms: 0, tests: [] };
        files.set(key, entry);
      }
      const last = test.results[test.results.length - 1];
      // A test an interrupt or a failed setup kept from running has no attempts.
      const state = last ? verdict(test) : 'skipped';
      counts[state] += 1;
      entry.duration_ms += test.results.reduce((sum, attempt) => sum + attempt.duration, 0);
      if (state === 'failed') entry.state = 'failed';
      else if (state === 'passed' && entry.state === 'skipped') entry.state = 'passed';
      const name = test.titlePath().slice(3).join(' > ');
      if (testsKept < MAX_TESTS) {
        testsKept += 1;
        entry.tests.push({ name, state, duration_ms: last?.duration });
      }
      if (state === 'failed') {
        for (const error of last.errors ?? []) failure('test', file, name, error);
      }
    }
    // An error located under a project's test directory is a spec file failing to
    // load, so it lists no tests. Anything else (global setup, webServer) is outside
    // every test.
    for (const error of this.errors) {
      const absolute = error?.location?.file;
      const spec = absolute && (this.testDirs ?? []).some((directory) => absolute.startsWith(directory + path.sep));
      if (!spec) {
        failure('unhandled', undefined, undefined, error);
        continue;
      }
      const file = relative(absolute);
      const entry = [...files.values()].find((candidate) => candidate.path === file);
      if (entry) entry.state = 'failed';
      else files.set(`\0${file}`, { path: file, state: 'failed', tests: [] });
      failure('module', file, undefined, error);
    }
    return { counts, files: [...files.values()], failures };
  }
}

module.exports = FyoloPlaywrightReporter;
