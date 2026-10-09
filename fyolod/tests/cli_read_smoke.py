#!/usr/bin/env python3
"""The daemon half of `fyolo sessions read` against a real fyolod.

Spawns a pinned-socket daemon, creates a session no window has ever opened,
and reads its screen through the Rust client with no app socket anywhere —
the Stage 10 gate that `read` works on a box with no Mac app, and that a
never-opened session answers instead of `not_live`.
"""

import json
import os
import shutil
import socket as socket_module
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FYOLOD = os.environ.get(
    "FYOLO_FYOLOD_TEST_BIN",
    os.path.join(REPO, "fyolod", "target", "debug", "fyolod"),
)
FYOLO = os.environ.get(
    "FYOLO_CLI_TEST_BIN",
    os.path.join(REPO, "fyolod", "target", "debug", "fyolo"),
)

BASE = f"/tmp/fyolo-read-{os.getpid()}"
HOME = os.path.join(BASE, "home")
SOCK = os.path.join(BASE, "fyolod.sock")

failures = []
passes = 0


def check(name, condition, detail=""):
    global passes
    if condition:
        passes += 1
        print(f"  [PASS] {name}")
    else:
        failures.append(name)
        print(f"  [FAIL] {name}\n{detail}")


def run(binary, args):
    env = {
        "HOME": HOME,
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "FYOLOD_SOCK": SOCK,
        "FYOLOD_KEEP_AWAKE": "off",
    }
    completed = subprocess.run(
        [binary] + args, env=env, cwd=HOME, capture_output=True, text=True, timeout=30
    )
    return completed.returncode, completed.stdout, completed.stderr


def main():
    shutil.rmtree(BASE, ignore_errors=True)
    os.makedirs(HOME)
    daemon = subprocess.Popen(
        [FYOLOD, "serve"],
        env={
            "HOME": HOME,
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "FYOLOD_SOCK": SOCK,
            "FYOLOD_KEEP_AWAKE": "off",
        },
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(100):
            if os.path.exists(SOCK):
                try:
                    probe = socket_module.socket(socket_module.AF_UNIX)
                    probe.connect(SOCK)
                    probe.close()
                    break
                except OSError:
                    pass
            time.sleep(0.05)
        else:
            print("daemon never bound its socket", file=sys.stderr)
            return 2

        name = "8D0FBEEF-0000-4000-8000-000000000001"
        code, out, err = run(
            FYOLOD,
            ["create", "--name", name, "--", "/bin/sh", "-c",
             "printf 'hello from the daemon screen\\n'; sleep 60"],
        )
        check("create", code == 0, f"    {code} {out!r} {err!r}")

        # The shell needs a moment to print; poll rather than trust a fixed
        # sleep on a loaded CI runner.
        deadline = time.time() + 15
        while True:
            code, out, err = run(FYOLO, ["sessions", "read", "8d0fbeef"])
            if code == 0 and "hello from the daemon screen" in out:
                break
            if time.time() > deadline:
                break
            time.sleep(0.3)
        check(
            "read by prefix, no app anywhere",
            code == 0 and "hello from the daemon screen" in out and err == "",
            f"    {code} {out!r} {err!r}",
        )

        code, out, err = run(FYOLO, ["sessions", "read", name.lower(), "--json"])
        try:
            reply = json.loads(out)
        except ValueError:
            reply = {}
        check(
            "read --json shape",
            code == 0
            and reply.get("ok") is True
            and reply.get("schema_version") == 1
            and "hello from the daemon screen" in reply.get("screen", "")
            and reply.get("target") == f"fyolo://session/{name.lower()}"
            and sorted(reply) == ["ok", "schema_version", "screen", "target", "title"],
            f"    {code} {out!r} {err!r}",
        )

        code, out, err = run(
            FYOLO, ["sessions", "read", f"fyolo://session/{name.lower()}", "--lines", "1"]
        )
        check(
            "read by link with --lines",
            code == 0 and out.rstrip("\n").splitlines()[-1:] != [] and "sleep" not in out,
            f"    {code} {out!r} {err!r}",
        )

        # A target the daemon does not own falls through to the app socket,
        # and with no app anywhere that is the app-missing error.
        code, out, err = run(FYOLO, ["sessions", "read", "ffffffff"])
        check(
            "unowned target falls through to the app path",
            code == 1 and "app is not running" in err,
            f"    {code} {out!r} {err!r}",
        )
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()
        shutil.rmtree(BASE, ignore_errors=True)

    print()
    if failures:
        print(f"{passes} passed, {len(failures)} FAILED: {failures}")
        return 1
    print(f"ALL {passes} CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
