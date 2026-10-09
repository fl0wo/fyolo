#!/usr/bin/env python3
"""redact.py — scrub a collected diagnostic bundle before it goes to a public issue.

Two modes:

    redact.py BUNDLE_DIR              rewrite every text file in place, print what changed
    redact.py BUNDLE_DIR --check      scan only; report anything that still looks sensitive

`--check` is not optional politeness: run it after redacting and read the output
before attaching anything to a GitHub issue. A rule that silently matched nothing
is indistinguishable from a rule that was never needed, and only the scan tells
the two apart.

Extra project paths worth scrubbing (repo names are often private) can be passed
with `--path /Users/me/work/secret-repo`, repeatable.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys

PLACEHOLDER = {
    "token": "<redacted-token>",
    "email": "<redacted-email>",
    "host": "<redacted-host>",
    "ip": "<redacted-ip>",
    "user": "USER",
}

# A rule is (label, pattern, replacement, line_guard). A rule carrying a
# line_guard is applied line by line and skipped on every line the guard matches.
Rule = tuple


def shell(*command: str) -> str:
    try:
        return subprocess.run(
            command, capture_output=True, text=True, timeout=5
        ).stdout.strip()
    except Exception:
        return ""


# A `sample` report ends in a Binary Images table whose version columns
# ("1104.0.0.1", "21624.1.1.10") are shaped exactly like IPv4 addresses. Letting
# the IP rule loose on those lines destroys the one section that identifies which
# framework build a stack came from, so the IP rule skips them.
IMAGE_LINE = re.compile(r"\.dylib|\.framework|com\.apple\.|\) <[0-9A-F]{8}-")

IPV4 = re.compile(r"\b(?!127\.0\.0\.1\b|0\.0\.0\.0\b|255\.255\.255\.255\b)"
                  r"(?:\d{1,3}\.){3}\d{1,3}\b")


def valid_ipv4(match) -> str:
    """Substitution guard: an octet above 255 is a version string, not an
    address. Keeps `6.3.2 - 1104.0.0.1` intact while still scrubbing real IPs."""
    if all(int(octet) <= 255 for octet in match.group(0).split(".")):
        return PLACEHOLDER["ip"]
    return match.group(0)


def build_rules(extra_paths):
    """Rules in application order. Most specific first: a home-directory rule
    that ran before the token rules would rewrite the context around a token and
    make it harder to see.
    """
    user = os.environ.get("USER") or shell("id", "-un")
    full_name = shell("id", "-F")
    computer_name = shell("scutil", "--get", "ComputerName")
    local_host = shell("scutil", "--get", "LocalHostName")

    rules = [
        # ---- credentials. Nothing in this block is worth leaking. ----
        ("private key block",
         re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S),
         "<redacted-private-key>", None),
        ("github token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{16,}\b"), PLACEHOLDER["token"], None),
        ("anthropic key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b"), PLACEHOLDER["token"], None),
        ("openai key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9]{20,}\b"), PLACEHOLDER["token"], None),
        ("slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"), PLACEHOLDER["token"], None),
        ("aws key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), PLACEHOLDER["token"], None),
        ("bearer header", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{16,}"),
         "Bearer " + PLACEHOLDER["token"], None),
        # Fields whose *name* says secret, whatever the value happens to look like.
        ("secret-named field",
         re.compile(r'("(?:[a-zA-Z_]*(?:token|secret|password|passphrase|api[_-]?key)[a-zA-Z_]*)"\s*:\s*)"[^"]*"', re.I),
         r'\1"' + PLACEHOLDER["token"] + '"', None),

        # ---- ingress. A live tunnel hostname is a door into the machine. ----
        ("cloudflare tunnel", re.compile(r"\b[a-z0-9][a-z0-9-]*\.trycloudflare\.com\b", re.I),
         PLACEHOLDER["host"], None),
        ("ngrok tunnel", re.compile(r"\b[a-z0-9][a-z0-9-]*\.ngrok(?:-free)?\.(?:app|io|dev)\b", re.I),
         PLACEHOLDER["host"], None),
        ("tailnet host", re.compile(r"\b[a-z0-9][a-z0-9.-]*\.ts\.net\b", re.I),
         PLACEHOLDER["host"], None),
        ("email", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
         PLACEHOLDER["email"], None),
    ]

    # Caller-supplied project paths run BEFORE the home-path rule. Once that rule
    # has rewritten /Users/<name> to /Users/USER, an absolute path passed on the
    # command line no longer matches anything — which is how a private repo name
    # survived a "successful" redaction pass and a clean --check.
    for path in extra_paths:
        cleaned = path.rstrip("/")
        if not cleaned:
            continue
        variants = {cleaned}
        if user:
            variants.add(cleaned.replace("/Users/" + user + "/", "/Users/USER/"))
            variants.add(cleaned.replace("/Users/" + user, "~"))
        for variant in variants:
            rules.append(("extra path", re.compile(re.escape(variant)), "<redacted-path>", None))

    rules += [
        ("home path", re.compile(r"""/Users/[^/\s"',:)\]]+"""),
         "/Users/" + PLACEHOLDER["user"], None),
        ("device key",
         re.compile(r'("(?:crashReporterKey|bootSessionUUID|sleepWakeUUID|deviceUDID|serialNumber|host_id)"\s*:\s*)"[^"]*"', re.I),
         r'\1"<redacted>"', None),
    ]

    if full_name and len(full_name) > 3:
        rules.append(("full name", re.compile(re.escape(full_name), re.I), "<redacted-name>", None))
    for name in (computer_name, local_host):
        if name and len(name) > 2:
            rules.append(("machine name", re.compile(re.escape(name), re.I), PLACEHOLDER["host"], None))
    # The username runs late and only as a whole word: substituting it earlier
    # would corrupt every path the home-path rule is meant to handle cleanly.
    if user and len(user) >= 3:
        rules.append(("username", re.compile(r"\b" + re.escape(user) + r"\b"),
                      PLACEHOLDER["user"], None))

    rules.append(("ip address", IPV4, valid_ipv4, IMAGE_LINE))
    return rules


# Patterns for --check: what a reviewer would flag in a public issue. The third
# element is an optional guard — `guard(line, match)` returning False means this
# hit is a false positive. Without it the IPv4 pattern fires on every dylib
# version in a sample's Binary Images table, and 156 cried-wolf findings are
# worse than no check at all.
def real_ip(line: str, match) -> bool:
    if IMAGE_LINE.search(line):
        return False
    return all(int(octet) <= 255 for octet in match.group(0).split("."))


SUSPICIOUS = [
    ("home path", re.compile(r"""/Users/(?!USER\b)[^/\s"',:)\]]+"""), None),
    ("email", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), None),
    ("token-shaped", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9-]{20,}|xox[abprs]-)"), None),
    ("tunnel host", re.compile(r"\b[a-z0-9-]+\.(?:trycloudflare\.com|ngrok(?:-free)?\.(?:app|io|dev)|ts\.net)\b", re.I), None),
    ("routable ip", re.compile(r"\b(?!127\.|0\.0\.0\.0|255\.|10\.|192\.168\.|169\.254\.)(?:\d{1,3}\.){3}\d{1,3}\b"), real_ip),
    ("secret-named field", re.compile(r'"[a-zA-Z_]*(?:token|secret|password|api[_-]?key)[a-zA-Z_]*"\s*:\s*"(?!<redacted)[^"]+"', re.I), None),
]

SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".mov", ".mp4", ".zip", ".gz", ".key"}


def text_files(root: pathlib.Path):
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() in SKIP_SUFFIXES:
            continue
        try:
            yield path, path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue


def redact(root: pathlib.Path, extra_paths) -> int:
    rules = build_rules(extra_paths)
    counts: dict[str, int] = {}
    touched = 0
    for path, original in text_files(root):
        text = original
        for label, pattern, replacement, line_guard in rules:
            if line_guard is None:
                text, hits = pattern.subn(replacement, text)
            else:
                hits = 0
                lines = text.split("\n")
                for index, line in enumerate(lines):
                    if line_guard.search(line):
                        continue
                    lines[index], line_hits = pattern.subn(replacement, line)
                    hits += line_hits
                text = "\n".join(lines)
            if hits:
                counts[label] = counts.get(label, 0) + hits
        if text != original:
            path.write_text(text, encoding="utf-8")
            touched += 1

    print(f"redacted {touched} file(s) under {root}")
    if counts:
        width = max(len(label) for label in counts)
        for label in sorted(counts, key=lambda k: -counts[k]):
            print(f"  {label:<{width}}  {counts[label]}")
    else:
        print("  (no rule matched — verify with --check before trusting that)")
    return 0


def check(root: pathlib.Path, extra_paths=()) -> int:
    # Paths the caller named as private are scanned for too, or --check would
    # report clean on a bundle that still spells out a private repo.
    patterns = list(SUSPICIOUS) + [
        ("named private path", re.compile(re.escape(path.rstrip('/'))), None)
        for path in extra_paths if path.strip()
    ]
    findings: list[tuple[str, str, int, str]] = []
    for path, text in text_files(root):
        for line_number, line in enumerate(text.splitlines(), 1):
            for label, pattern, guard in patterns:
                match = pattern.search(line)
                if match and (guard is None or guard(line, match)):
                    findings.append((label, str(path.relative_to(root)), line_number,
                                     match.group(0)[:80]))
                    break

    if not findings:
        print(f"clean: nothing suspicious left in {root}")
        return 0

    by_label: dict[str, list] = {}
    for label, rel, line_number, sample in findings:
        by_label.setdefault(label, []).append((rel, line_number, sample))
    print(f"{len(findings)} line(s) still look sensitive in {root}:\n")
    for label, rows in by_label.items():
        print(f"{label} — {len(rows)}")
        for rel, line_number, sample in rows[:5]:
            print(f"    {rel}:{line_number}  {sample}")
        if len(rows) > 5:
            print(f"    … {len(rows) - 5} more")
        print()
    print("Fix with --path for project directories, or delete the offending file "
          "from the bundle. Do not attach the bundle until this is clean.")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("bundle", type=pathlib.Path)
    parser.add_argument("--check", action="store_true",
                        help="scan without modifying; exit 1 if anything looks sensitive")
    parser.add_argument("--path", action="append", default=[],
                        help="an extra absolute path to scrub (repeatable)")
    arguments = parser.parse_args()

    if not arguments.bundle.is_dir():
        print(f"redact.py: {arguments.bundle} is not a directory", file=sys.stderr)
        return 2
    if arguments.check:
        return check(arguments.bundle, arguments.path)
    return redact(arguments.bundle, arguments.path)


if __name__ == "__main__":
    raise SystemExit(main())
