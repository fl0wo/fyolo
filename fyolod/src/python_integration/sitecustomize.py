# fyolod appends this directory to PYTHONPATH in every session it spawns, so this
# file runs at the start of every Python process there. Outside pytest it costs
# one argv check. Inside pytest it names fyolo's plugin in PYTEST_PLUGINS for this
# process only, and the plugin restores the variable on import. Then the next
# sitecustomize on sys.path runs, as if this one were not here.
#
# PYTEST_PLUGINS is never set in the session itself: a PYTHONPATH that loses this
# directory (`PYTHONPATH=src pytest`, `python -I`, tox) would then make pytest stop
# on a plugin it cannot import. Set here, the plugin is importable by construction.
#
# Written in syntax every Python 2.7+ parses, because an old interpreter runs it too.
import sys


def _fyolo_pytest_wanted():
    import os
    if not os.environ.get('FYOLOD_SOCK') or 'FYOLOD_PYTEST_RUN' in os.environ or not _fyolo_is_pytest():
        return False
    # Switched off in fyolo's settings since this session started (see
    # fyolod/src/test_runners.rs).
    return not os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pytest.off'))


def _fyolo_is_pytest():
    import os
    argv = getattr(sys, 'orig_argv', None)
    if argv:
        arguments = argv[1:]
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument == '-m':
                return index + 1 < len(arguments) and arguments[index + 1] == 'pytest'
            if argument.startswith('-m'):
                return argument[2:] == 'pytest'
            if argument in ('-c', '-') or not argument.startswith('-'):
                break
            if argument in ('-W', '-X', '-Q'):
                index += 1
            index += 1
    elif sys.argv and sys.argv[0] == '-m':
        # Before 3.10 the module name is gone from argv at this point. Linux still
        # has it in the kernel's copy; elsewhere `python -m pytest` on 3.8 and 3.9
        # runs unrecorded.
        try:
            with open('/proc/self/cmdline', 'rb') as handle:
                arguments = handle.read().split(b'\0')
            index = arguments.index(b'-m')
            return arguments[index + 1] == b'pytest'
        except Exception:
            return False
    return (os.path.basename(sys.argv[0]) if sys.argv else '') in ('pytest', 'py.test')


def _fyolo_restore():
    # A parent pytest that named the plugin but never imported it (blocked with
    # `-p no:fyolo_pytest`) leaves the variable extended; undo that here.
    import os
    previous = os.environ.pop('FYOLOD_PYTEST_PREVIOUS_PLUGINS', None)
    if previous is not None:
        if previous:
            os.environ['PYTEST_PLUGINS'] = previous
        else:
            os.environ.pop('PYTEST_PLUGINS', None)


def _fyolo_enable():
    import os
    previous = os.environ.get('PYTEST_PLUGINS')
    os.environ['FYOLOD_PYTEST_PREVIOUS_PLUGINS'] = previous or ''
    os.environ['PYTEST_PLUGINS'] = (previous + ',' if previous else '') + 'fyolo_pytest'


def _fyolo_next_sitecustomize():
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    path = [entry for entry in sys.path if os.path.abspath(entry or '.') != here]
    # The import system's own frozen module, already loaded. importlib would cost
    # every Python process a fifth of a millisecond.
    return sys.modules['_frozen_importlib_external'].PathFinder.find_spec('sitecustomize', path)


try:
    _fyolo_restore()
    if _fyolo_pytest_wanted():
        _fyolo_enable()
except Exception:
    pass

try:
    _fyolo_next = _fyolo_next_sitecustomize()
except Exception:
    _fyolo_next = None

if _fyolo_next is not None:
    # Outside the try: the user's sitecustomize raises exactly as it would without
    # this file.
    _fyolo_module = sys.modules['_frozen_importlib'].module_from_spec(_fyolo_next)
    sys.modules['sitecustomize'] = _fyolo_module
    _fyolo_next.loader.exec_module(_fyolo_module)
