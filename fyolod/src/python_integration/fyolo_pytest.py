"""PYTEST_DONT_REWRITE"""
# fyolo's pytest plugin, named in PYTEST_PLUGINS by sitecustomize.py for a pytest
# process only. It reports each run to the session's fyolod over the session
# protocol's framing, as the Node reporters do (fyolod/src/node_integration).
#
# It never writes to stdout or stderr, and every failure is silent: the user's
# terminal output is byte-identical with and without it. Sending happens on one
# background thread that only ever holds the newest progress report, so a slow
# daemon never holds up a test.
import functools
import json
import os
import re
import socket
import struct
import textwrap
import threading
import time
import uuid

import pytest

KIND_CONTROL = 0x43
PROGRESS_INTERVAL = 0.25
FINAL_DRAIN = 0.5
MAX_FAILURES = 200
MAX_TESTS = 20000
MAX_TEXT = 8192

# Give children (tests that spawn Python, xdist workers) the user's own value back.
_previous = os.environ.pop('FYOLOD_PYTEST_PREVIOUS_PLUGINS', None)
if _previous is not None:
    if _previous:
        os.environ['PYTEST_PLUGINS'] = _previous
    else:
        os.environ.pop('PYTEST_PLUGINS', None)

# pytest's own categories (rerunfailures and other plugins add theirs through the
# same hook) reduced to the three every runner shares.
_STATES = {'passed': 'passed', 'xpassed': 'passed', 'skipped': 'skipped', 'xfailed': 'skipped',
           'failed': 'failed', 'error': 'failed'}
_RANK = {'passed': 0, 'skipped': 1, 'failed': 2}


def _quiet(hook):
    """An exception in fyolo's code must never reach pytest."""
    @functools.wraps(hook)
    def guarded(*arguments, **keywords):
        try:
            return hook(*arguments, **keywords)
        except Exception:
            return None
    return guarded


def _encode(message):
    payload = json.dumps(message).encode('utf-8')
    return struct.pack('>BI', KIND_CONTROL, len(payload)) + payload


def _text(value):
    if not value:
        return None
    value = str(value)
    return value if len(value) <= MAX_TEXT else value[:MAX_TEXT] + '…'


def _repository_root(directory):
    current = directory
    while True:
        if os.path.exists(os.path.join(current, '.git')):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return directory
        current = parent


class _Channel(object):
    """The connection to fyolod, owned by one daemon thread. Progress is pulled
    from `snapshot` at most every PROGRESS_INTERVAL while something changed; the
    final report is queued once and waited on for at most FINAL_DRAIN."""

    def __init__(self, snapshot):
        self.snapshot = snapshot
        self.condition = threading.Condition()
        self.changed = False
        self.final = None
        self.done = False
        thread = threading.Thread(target=self._run, name='fyolo-test-runs')
        thread.daemon = True
        thread.start()

    def touch(self):
        with self.condition:
            if not self.changed:
                self.changed = True
                self.condition.notify()

    def finish(self, message):
        with self.condition:
            self.final = message
            self.condition.notify()
            deadline = time.monotonic() + FINAL_DRAIN
            while not self.done:
                left = deadline - time.monotonic()
                if left <= 0:
                    return
                self.condition.wait(left)

    def _run(self):
        try:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.connect(os.environ['FYOLOD_SOCK'])
            connection.sendall(_encode({'op': 'hello', 'proto': 1, 'min_proto': 1, 'role': 'control',
                                        'caps': ['test_runs'], 'client': 'fyolo-pytest'}))
            sent = 0.0
            while True:
                with self.condition:
                    while not self.changed and self.final is None:
                        self.condition.wait()
                    final = self.final
                if final is None:
                    pause = sent + PROGRESS_INTERVAL - time.monotonic()
                    if pause > 0:
                        with self.condition:
                            self.condition.wait(pause)
                        continue
                    with self.condition:
                        self.changed = False
                    connection.sendall(_encode(self.snapshot()))
                    sent = time.monotonic()
                    continue
                connection.sendall(_encode(final))
                break
        except Exception:
            pass
        with self.condition:
            self.done = True
            self.condition.notify_all()


class FyoloTestRuns(object):
    def __init__(self, config):
        self.config = config
        self.rootdir = str(config.rootpath)
        self.root = _repository_root(self.rootdir)
        self.id = str(uuid.uuid4())
        self.started_at = int(time.time() * 1000)
        self.started = time.monotonic()
        self.argv = list(config.invocation_params.args)
        # nodeid -> [state or None while undecided, seconds]
        self.tests = {}
        self.counts = {'passed': 0, 'failed': 0, 'skipped': 0}
        self.file_totals = {}
        self.file_left = {}
        self.modules = set()
        self.files_done = set()
        self.tests_done = set()
        self.module_failures = set()
        self.module_skips = set()
        self.failures = []
        self.interrupted = False
        self.channel = _Channel(self._snapshot)

    # Paths

    def _file(self, nodeid):
        file = nodeid.split('::', 1)[0]
        try:
            return os.path.relpath(os.path.join(self.rootdir, file), self.root)
        except Exception:
            return file

    def _inside(self, path):
        path = os.path.abspath(os.path.join(self.rootdir, path))
        if path.startswith(self.root + os.sep) and os.sep + 'site-packages' + os.sep not in path:
            return os.path.relpath(path, self.root)
        return None

    def _location(self, report):
        crash = getattr(getattr(report, 'longrepr', None), 'reprcrash', None)
        if crash is not None and crash.path and self._inside(crash.path):
            return '%s:%s' % (self._inside(crash.path), crash.lineno)
        location = getattr(report, 'location', None)
        if location and location[1] is not None:
            return '%s:%s' % (self._file(location[0]), location[1] + 1)
        return None

    # Failures

    def _failure(self, kind, report, test):
        if len(self.failures) >= MAX_FAILURES:
            return
        text = getattr(report, 'longreprtext', '') or ''
        if kind == 'module':
            # A collection error's text is a traceback into importlib; the error
            # itself is the trailing "E" block.
            lines = text.split('\n')
            error = [line[4:] for line in lines if line.startswith('E   ')]
            message = error[-1].strip() if error else (lines[0] if lines else None)
            diff = '\n'.join(error[:-1]) if len(error) > 1 else None
            location = None
            for line in lines:
                found = re.match(r'^(\S+?):(\d+): in ', line) or re.search(r'File "(.+)", line (\d+)', line)
                if found and self._inside(found.group(1)):
                    location = '%s:%s' % (self._inside(found.group(1)), found.group(2))
        else:
            crash = getattr(getattr(report, 'longrepr', None), 'reprcrash', None)
            lines = ((crash.message if crash is not None else text) or '').split('\n')
            message = lines[0]
            # The rest is the assertion rewriter's explanation: the diff.
            diff = textwrap.dedent('\n'.join(lines[1:])).strip('\n') or None
            location = self._location(report)
        failure = {'kind': kind, 'file': self._file(report.nodeid) if report.nodeid else None, 'test': test,
                   'message': _text(message), 'diff': _text(diff), 'location': location}
        self.failures.append((report.nodeid, dict((k, v) for k, v in failure.items() if v is not None)))

    # Counts

    def _decide(self, nodeid, state):
        entry = self.tests[nodeid]
        if entry[0] is not None and _RANK[state] <= _RANK[entry[0]]:
            return
        if entry[0] is not None:
            self.counts[entry[0]] -= 1
        entry[0] = state
        self.counts[state] += 1

    def _set_totals(self, nodeids):
        totals = {}
        for nodeid in nodeids:
            file = self._file(nodeid)
            totals[file] = totals.get(file, 0) + 1
        self.file_totals = totals
        self.file_left = dict(totals)

    # Hooks

    @_quiet
    def pytest_sessionstart(self, session):
        # A pytest that this run starts (pytester, a test running `python -m
        # pytest`) is part of this run, not a run of its own.
        os.environ['FYOLOD_PYTEST_RUN'] = self.id
        self.channel.touch()

    @_quiet
    def pytest_collectreport(self, report):
        nodeid = report.nodeid or ''
        if not nodeid or '::' in nodeid:
            return
        if nodeid.endswith('.py'):
            self.modules.add(self._file(nodeid))
        if report.failed:
            self.module_failures.add(self._file(nodeid))
            self._failure('module', report, None)
            self.channel.touch()
        elif report.skipped:
            self.module_skips.add(self._file(nodeid))

    @_quiet
    def pytest_collection_finish(self, session):
        self._set_totals([item.nodeid for item in session.items])
        self.channel.touch()

    @_quiet
    def pytest_runtest_logreport(self, report):
        category = self.config.hook.pytest_report_teststatus(report=report, config=self.config)[0]
        nodeid = report.nodeid
        entry = self.tests.get(nodeid)
        if entry is None:
            entry = self.tests[nodeid] = [None, 0.0]
        if category == 'rerun':
            # rerunfailures runs the test again: only the last attempt counts.
            if entry[0] is not None:
                self.counts[entry[0]] -= 1
            entry[0] = None
            entry[1] = 0.0
            self.failures = [failure for failure in self.failures if failure[0] != nodeid]
            return
        entry[1] += report.duration or 0.0
        state = _STATES.get(category)
        if state is not None:
            self._decide(nodeid, state)
        if report.failed:
            test = nodeid.split('::', 1)[1] if '::' in nodeid else nodeid
            self._failure('test', report, test if report.when == 'call' else '%s (%s)' % (test, report.when))
        if report.when == 'teardown' and entry[0] is not None and nodeid not in self.tests_done:
            self.tests_done.add(nodeid)
            file = self._file(nodeid)
            if file in self.file_left:
                self.file_left[file] -= 1
                if self.file_left[file] <= 0:
                    self.files_done.add(file)
        self.channel.touch()

    @_quiet
    def pytest_internalerror(self, excrepr, excinfo):
        if len(self.failures) < MAX_FAILURES:
            crash = getattr(excrepr, 'reprcrash', None)
            self.failures.append((None, {'kind': 'unhandled',
                                         'message': _text(crash.message if crash else str(excrepr))}))

    @_quiet
    def pytest_keyboard_interrupt(self, excinfo):
        self.interrupted = True

    # trylast: every other plugin has settled the exit status first.
    @pytest.hookimpl(trylast=True)
    @_quiet
    def pytest_sessionfinish(self, session, exitstatus):
        os.environ.pop('FYOLOD_PYTEST_RUN', None)
        files = {}
        kept = 0
        for nodeid, (state, seconds) in self.tests.items():
            if state is None:
                continue
            file = self._file(nodeid)
            entry = files.get(file)
            if entry is None:
                entry = files[file] = {'path': file, 'state': 'skipped', 'duration_ms': 0.0, 'tests': []}
            if kept < MAX_TESTS:
                kept += 1
                entry['tests'].append({'name': nodeid.split('::', 1)[-1], 'state': state,
                                       'duration_ms': seconds * 1000})
            entry['duration_ms'] += seconds * 1000
            if state == 'failed' or (state == 'passed' and entry['state'] == 'skipped'):
                entry['state'] = state
        for file in self.module_failures:
            files.setdefault(file, {'path': file, 'state': 'failed', 'tests': []})['state'] = 'failed'
        for file in self.module_skips:
            files.setdefault(file, {'path': file, 'state': 'skipped', 'tests': []})
        message = self._snapshot()
        message['files_done'] = message['files_total'] = len(files) or message['files_total']
        if self.interrupted:
            message['state'] = 'interrupted'
        else:
            # 2 is also "collection errors stopped the run", so it isn't read as an
            # interrupt on its own.
            message['state'] = 'passed' if int(exitstatus) == 0 else 'failed'
        message['detail'] = {'files': list(files.values()), 'failures': [failure for _, failure in self.failures]}
        self.channel.finish(message)

    # Reporting

    def _snapshot(self):
        counts = dict(self.counts)
        counts['skipped'] += len(self.module_skips)
        message = {
            'op': 'report_test_run', 'runner': 'pytest', 'id': self.id, 'root': self.root,
            'session': os.environ.get('FYOLOD_SESSION_ID') or None,
            'command_id': os.environ.get('FYOLOD_COMMAND_ID') or None,
            'command': os.environ.get('FYOLOD_COMMAND') or None,
            'argv': self.argv,
            'started_at': self.started_at,
            'duration_ms': int((time.monotonic() - self.started) * 1000),
            'files_total': len(self.modules.union(self.file_totals)),
            'files_done': len(self.files_done.union(self.module_failures, self.module_skips)),
            'counts': counts, 'state': 'running',
        }
        return dict((k, v) for k, v in message.items() if v is not None)


class _XdistController(object):
    """Only an xdist controller has this hook. It never collects; every worker
    sends the same ids."""

    def __init__(self, run):
        self.run = run

    @pytest.hookimpl(optionalhook=True)
    @_quiet
    def pytest_xdist_node_collection_finished(self, node, ids):
        if not self.run.file_totals:
            self.run._set_totals(ids)
            self.run.channel.touch()


def _supported():
    try:
        return int(pytest.__version__.split('.')[0]) >= 8
    except Exception:
        return False


def pytest_configure(config):
    try:
        # A worker's results reach the controller, which reports them.
        if not _supported() or hasattr(config, 'workerinput') or not os.environ.get('FYOLOD_SOCK'):
            return
        option = config.option
        if getattr(option, 'help', False) or getattr(option, 'version', False) or getattr(option, 'collectonly', False):
            return
        run = FyoloTestRuns(config)
        config.pluginmanager.register(run, 'fyolo-test-runs')
        if config.pluginmanager.hasplugin('xdist'):
            config.pluginmanager.register(_XdistController(run), 'fyolo-test-runs-xdist')
    except Exception:
        pass
