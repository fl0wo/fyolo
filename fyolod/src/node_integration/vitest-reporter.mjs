// fyolo's Vitest reporter. It reports each run to the session's fyolod over the
// session protocol's own framing, so the run becomes a protocol object rather than
// something read back off the screen.
//
// It never writes to stdout or stderr, and every failure is silent. The user's
// terminal output must be byte-identical with and without it.

import path from 'node:path';
import { randomUUID } from 'node:crypto';
import {
  Channel,
  plain,
  repositoryRoot,
  packageName,
  sessionFields,
  PROGRESS_INTERVAL_MS,
  MAX_FAILURES,
  MAX_TESTS,
} from './channel.cjs';

const attached = new WeakSet();

export function fyoloTestRunsPlugin() {
  return {
    name: 'fyolo:test-runs',
    configureVitest({ vitest }) {
      // Every project server carries this plugin; one reporter per Vitest is enough.
      if (attached.has(vitest)) return;
      attached.add(vitest);
      try {
        vitest.config.reporters.push(new FyoloReporter());
      } catch {
        // A Vitest whose config shape differs runs uncaptured.
      }
    },
  };
}

class FyoloReporter {
  onInit(vitest) {
    this.vitest = vitest;
    this.channel = new Channel('fyolo-vitest');
    this.vitestRoot = vitest.config.root;
    this.root = repositoryRoot(this.vitestRoot);
    this.package = packageName(this.vitestRoot);
  }

  onTestRunStart(specifications) {
    this.run = randomUUID();
    this.startedAt = Date.now();
    this.filesTotal = new Set(specifications.map((specification) => specification.moduleId)).size;
    this.filesDone = 0;
    this.counts = { passed: 0, failed: 0, skipped: 0 };
    this.report();
    this.timer = setInterval(() => this.flushProgress(), PROGRESS_INTERVAL_MS);
    this.timer.unref();
  }

  onTestCaseResult(testCase) {
    const state = testCase.result().state;
    if (state in this.counts) this.counts[state] += 1;
    this.dirty = true;
  }

  onTestModuleEnd() {
    this.filesDone += 1;
    this.dirty = true;
  }

  flushProgress() {
    if (!this.dirty) return;
    this.dirty = false;
    this.report();
  }

  async onTestRunEnd(testModules, unhandledErrors, reason) {
    clearInterval(this.timer);
    const detail = this.detail(testModules, unhandledErrors);
    this.counts = detail.counts;
    this.filesDone = detail.files.length;
    const state = reason === 'interrupted' ? 'interrupted' : reason === 'failed' ? 'failed' : 'passed';
    await this.report({ state, detail: { files: detail.files, failures: detail.failures } }, true);
  }

  report(extra = {}, final = false) {
    if (!this.channel || !this.run) return Promise.resolve();
    return this.channel[final ? 'sendFinal' : 'send']({
      op: 'report_test_run',
      runner: 'vitest',
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

  detail(testModules, unhandledErrors) {
    const counts = { passed: 0, failed: 0, skipped: 0 };
    const files = [];
    const failures = [];
    let testsKept = 0;
    const relative = (file) => (file ? path.relative(this.root, file) : undefined);
    const failure = (kind, file, test, error) => {
      if (failures.length >= MAX_FAILURES) return;
      const frame = error?.stacks?.[0];
      failures.push({
        kind,
        file,
        test,
        message: plain(`${error?.name && error.name !== 'Error' ? `${error.name}: ` : ''}${error?.message ?? String(error)}`),
        diff: plain(error?.diff),
        location: frame?.file ? `${relative(frame.file)}:${frame.line}` : undefined,
      });
    };

    for (const testModule of testModules) {
      const file = relative(testModule.moduleId);
      const tests = [];
      for (const testCase of testModule.children.allTests()) {
        const result = testCase.result();
        if (result.state in counts) counts[result.state] += 1;
        if (testsKept < MAX_TESTS) {
          testsKept += 1;
          tests.push({ name: testCase.fullName, state: result.state, duration_ms: testCase.diagnostic()?.duration });
        }
        if (result.state === 'failed') {
          for (const error of result.errors ?? []) failure('test', file, testCase.fullName, error);
        }
      }
      const moduleErrors = testModule.errors();
      for (const error of moduleErrors) failure('module', file, undefined, error);
      files.push({
        path: file,
        project: testModule.project?.name || undefined,
        state: moduleErrors.length ? 'failed' : testModule.state(),
        duration_ms: testModule.diagnostic()?.duration,
        tests,
      });
    }
    for (const error of unhandledErrors) failure('unhandled', undefined, undefined, error);
    return { counts, files, failures };
  }
}
