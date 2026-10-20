// What every Node reporter shares: the connection to the session's fyolod, which
// speaks the session protocol's own framing, and the fields every report carries.
// CommonJS, so the Playwright reporter can require it and the Vitest reporter can
// import it.
//
// Nothing here writes to stdout or stderr, and every failure is silent. The user's
// terminal output must be byte-identical with and without a reporter.
'use strict';

const net = require('node:net');
const path = require('node:path');
const fs = require('node:fs');

const KIND_CONTROL = 0x43;
const MAX_TEXT = 8192;

exports.PROGRESS_INTERVAL_MS = 250;
exports.FINAL_DRAIN_MS = 500;
exports.MAX_FAILURES = 200;
exports.MAX_TESTS = 20000;

function encode(message) {
  const payload = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(5);
  header[0] = KIND_CONTROL;
  header.writeUInt32BE(payload.length, 1);
  return Buffer.concat([header, payload]);
}

class Channel {
  constructor(client) {
    this.dead = false;
    try {
      this.socket = net.createConnection(process.env.FYOLOD_SOCK);
      this.socket.on('error', () => {
        this.dead = true;
      });
      // Replies are not needed; reading them keeps the daemon's writes from stalling.
      this.socket.on('data', () => {});
      // A watch-mode runner that the user quits must not stay alive for this socket.
      this.socket.unref();
      this.socket.write(encode({ op: 'hello', proto: 1, min_proto: 1, role: 'control', caps: ['test_runs'], client }));
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

  // The last report of a run, waited on for at most FINAL_DRAIN_MS so a stalled
  // daemon never holds the runner's exit.
  sendFinal(message) {
    return Promise.race([
      this.send(message),
      new Promise((resolve) => setTimeout(resolve, exports.FINAL_DRAIN_MS).unref()),
    ]);
  }
}
exports.Channel = Channel;

// The fields that place a run: the session and the shell command line it ran under.
exports.sessionFields = function sessionFields() {
  return {
    session: process.env.FYOLOD_SESSION_ID || undefined,
    command_id: process.env.FYOLOD_COMMAND_ID || undefined,
    command: process.env.FYOLOD_COMMAND || undefined,
  };
};

// Strips SGR and other CSI sequences, which runners leave in messages and diffs.
exports.plain = function plain(text) {
  if (typeof text !== 'string') return undefined;
  const stripped = text.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '');
  return stripped.length > MAX_TEXT ? `${stripped.slice(0, MAX_TEXT)}…` : stripped;
};

exports.repositoryRoot = function repositoryRoot(directory) {
  let current = directory;
  for (;;) {
    if (fs.existsSync(path.join(current, '.git'))) return current;
    const parent = path.dirname(current);
    if (parent === current) return directory;
    current = parent;
  }
};

exports.packageName = function packageName(directory) {
  try {
    return JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8')).name || undefined;
  } catch {
    return undefined;
  }
};
