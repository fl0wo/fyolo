// fyolo's Vitest reporter. It reports each run to the session's fyolod over the
// session protocol's own framing, so the run becomes a protocol object rather than
// something read back off the screen.
//
// It never writes to stdout or stderr, and every failure is silent. The user's
// terminal output must be byte-identical with and without it.

import net from 'node:net';
import path from 'node:path';
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';

const KIND_CONTROL = 0x43;
const PROGRESS_INTERVAL_MS = 250;
const FINAL_DRAIN_MS = 500;
const MAX_FAILURES = 200;
const MAX_TESTS = 20000;
const MAX_TEXT = 8192;

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

function encode(message) {
  const payload = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(5);
  header[0] = KIND_CONTROL;
  header.writeUInt32BE(payload.length, 1);
  return Buffer.concat([header, payload]);
}

class Channel {
  constructor(socketPath) {
    this.dead = false;
    try {
      this.socket = net.createConnection(socketPath);
      this.socket.on('error', () => {
        this.dead = true;
      });
      // Replies are not needed; reading them keeps the daemon's writes from stalling.
      this.socket.on('data', () => {});
      // A watch-mode Vitest that the user quits must not stay alive for this socket.
      this.socket.unref();
      this.socket.write(
        encode({ op: 'hello', proto: 1, min_proto: 1, role: 'control', caps: ['test_runs'], client: 'fyolo-vitest' }),
      );
    } catch {
      this.dead = true;
    }
  }

  send(message) {
    if (this.dead) return Promise.resolve();
    return new Promise((resolve) => {
      try {
        this.socket.write(encode(message), () => resolve());
      } catch {
        this.dead = true;
        resolve();
      }
    });
  }
}

// Strips SGR and other CSI sequences, which Vitest leaves in diffs.
function plain(text) {
  if (typeof text !== 'string') return undefined;
  const stripped = text.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '');
  return stripped.length > MAX_TEXT ? `${stripped.slice(0, MAX_TEXT)}…` : stripped;
}

function repositoryRoot(directory) {
  let current = directory;
  for (;;) {
    if (fs.existsSync(path.join(current, '.git'))) return current;
    const parent = path.dirname(current);
    if (parent === current) return directory;
    current = parent;
  }
}

function packageName(directory) {
  try {
    return JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8')).name || undefined;
  } catch {
    return undefined;
  }
}

class FyoloReporter {
  onInit(vitest) {
    this.vitest = vitest;
    this.channel = new Channel(process.env.FYOLOD_SOCK);
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
    const sent = this.report({ state, detail: { files: detail.files, failures: detail.failures } });
    await Promise.race([sent, new Promise((resolve) => setTimeout(resolve, FINAL_DRAIN_MS).unref())]);
  }

  report(extra = {}) {
    if (!this.channel || !this.run) return Promise.resolve();
    return this.channel.send({
      op: 'report_test_run',
      id: this.run,
      root: this.root,
      package: this.package,
      session: process.env.FYOLOD_SESSION_ID || undefined,
      command_id: process.env.FYOLOD_COMMAND_ID || undefined,
      command: process.env.FYOLOD_COMMAND || undefined,
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
