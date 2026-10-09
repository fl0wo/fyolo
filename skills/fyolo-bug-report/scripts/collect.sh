#!/bin/bash
# collect.sh — gather everything needed to diagnose a fyolo hang, crash, or
# misbehaviour into one directory, ready for redact.py.
#
# The single most perishable artifact is a `sample` of a *live* hung process:
# once the user force-quits, the stack that explains the beachball is gone
# forever. So sampling runs first, before anything slower.
#
# usage: collect.sh [--minutes N] [--out DIR] [--no-sample] [--channel release|dev|both]
set -uo pipefail

MINUTES=60
OUT=""
DO_SAMPLE=1
CHANNEL=both

while [ $# -gt 0 ]; do
    case "$1" in
        --minutes) MINUTES="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --no-sample) DO_SAMPLE=0; shift ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "collect.sh: unknown option $1" >&2; exit 2 ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
[ -n "$OUT" ] || OUT="${TMPDIR:-/tmp}/fyolo-bugreport-$STAMP"
mkdir -p "$OUT" || exit 1
note() { printf '%s\n' "$*" >>"$OUT/collect.log"; }
note "collect.sh $STAMP  minutes=$MINUTES channel=$CHANNEL sample=$DO_SAMPLE"

# ---------------------------------------------------------------- 1. samples
# `sample` needs no root for your own processes and takes ~1s longer than the
# duration you ask for. A hung main thread shows as the whole sample sitting in
# one call — that line is the answer.
# `pgrep` is unreliable here: it silently misses `fyolod` even with -f, so pid
# discovery goes through ps, matching the executable path ps reports in COMM.
pids_matching() { ps -Ao pid=,comm= | awk -v pattern="$1" '$2 ~ pattern { print $1 }'; }
release_app_pids=$(pids_matching '/fyolo\.app/Contents/MacOS/fyolo$')
dev_app_pids=$(pids_matching 'fyolo-dev\.app/Contents/MacOS/fyolo$')
daemon_pids=$(pids_matching '/fyolod$|^fyolod$')

case "$CHANNEL" in
    release) app_pids="$release_app_pids" ;;
    dev)     app_pids="$dev_app_pids" ;;
    *)       app_pids="$release_app_pids $dev_app_pids" ;;
esac

if [ "$DO_SAMPLE" = 1 ]; then
    for pid in $app_pids $daemon_pids; do
        [ -n "$pid" ] || continue
        name=$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)")
        echo "sampling $name [$pid] for 3s…" >&2
        /usr/bin/sample "$pid" 3 -file "$OUT/sample-$name-$pid.txt" >/dev/null 2>&1 \
            && note "sampled $name $pid" \
            || note "sample failed for $name $pid (already exited, or needs Developer Tools permission)"
    done
else
    note "sampling skipped (--no-sample)"
fi

# --------------------------------------------------------------- 2. the app
{
    echo "# Environment"
    echo
    echo "collected: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "macOS:     $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "hardware:  $(sysctl -n hw.model 2>/dev/null)  $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    echo "memory:    $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
    echo
    for app in /Applications/fyolo.app "$HOME/Applications/fyolo.app" ./fyolo-dev.app; do
        [ -d "$app" ] || continue
        version=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null)
        build=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleVersion 2>/dev/null)
        id=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)
        echo "installed: $app — $version ($build) $id"
    done
    echo
    echo "## Processes"
    ps -Ao pid,ppid,%cpu,%mem,etime,command | grep -i 'fyolo' | grep -v ' grep ' || echo "(none running)"
    echo
    echo "## Daemon"
    for candidate in /Applications/fyolo.app/Contents/Resources/fyolod \
                     ./fyolo-dev.app/Contents/Resources/fyolod \
                     "$(command -v fyolod 2>/dev/null)"; do
        [ -x "$candidate" ] || continue
        echo "$candidate: $("$candidate" --version 2>&1 | head -1)"
    done
    echo
    echo "## Agent CLIs"
    for cli in claude codex opencode amp gemini grok cursor-agent; do
        path=$(command -v "$cli" 2>/dev/null) || continue
        echo "$cli: $("$cli" --version 2>&1 | head -1)  [$path]"
    done
} >"$OUT/environment.md" 2>&1

# ---------------------------------------------------- 3. unified log (os_log)
# `log` is shadowed by a shell function in some profiles — always the full path.
# `--info --debug` matters: without them `log show` drops everything below
# .notice, which is where fyolo's operational trail and every Trace timing live.
/usr/bin/log show --last "${MINUTES}m" --info --debug --style compact \
    --predicate 'subsystem BEGINSWITH "sh.fyolo"' \
    >"$OUT/unified-log-fyolo.txt" 2>&1
note "unified-log-fyolo.txt: $(wc -l <"$OUT/unified-log-fyolo.txt" | tr -d ' ') lines"

# Anything the *system* said about the processes — WindowServer kills, jetsam,
# hang detection, code signing. fyolo's own subsystem cannot report its own
# death. runningboardd is deliberately excluded: it emits thousands of assertion
# lines per half hour that bury the couple hundred that matter.
/usr/bin/log show --last "${MINUTES}m" --info --style compact \
    --predicate 'process == "fyolo" OR process == "fyolod" OR (eventMessage CONTAINS[c] "fyolo" AND (process == "WindowServer" OR process == "symptomsd" OR process == "kernel"))' \
    >"$OUT/unified-log-system.txt" 2>&1
note "unified-log-system.txt: $(wc -l <"$OUT/unified-log-system.txt" | tr -d ' ') lines"

# ------------------------------------ 4. what macOS itself recorded
# Four different things land in DiagnosticReports and they answer different
# questions, so all four are collected:
#   *.ips                       a crash (has "exception" + "termination") or,
#                               where hang reporting is on, an unresponsiveness
#                               report (has "duration"/"processByPid", no exception)
#   *.hang / *.spin             older-style unresponsiveness reports
#   *.cpu_resource.diag         the OS caught the process burning CPU — the
#                               Microstackshots in it are a free beachball stack
#   *.wakeups_resource.diag     the OS caught it waking too often (idle CPU burn)
# The per-user directory needs no privileges; the system one is world-readable
# for these files.
mkdir -p "$OUT/reports"
for dir in "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 1 -type f \( -name 'fyolo*' -o -name 'GhosttyKit*' \) \
        \( -name '*.ips' -o -name '*.hang' -o -name '*.spin' -o -name '*.crash' -o -name '*.diag' \) \
        -mtime -14 -exec cp {} "$OUT/reports/" \; 2>/dev/null
done

# One line per report, so the shape of the evidence is readable without opening
# a 68 KB JSON blob to find out it was an unrelated launch failure.
python3 - "$OUT/reports" >"$OUT/reports/index.md" 2>/dev/null <<'INDEX'
import json, pathlib, sys

directory = pathlib.Path(sys.argv[1])
print("# Reports macOS wrote\n")
rows = sorted(p for p in directory.iterdir() if p.suffix != ".md")
if not rows:
    print("(none in the last 14 days)")
for path in rows:
    if path.suffix == ".diag":
        text = path.read_text(errors="replace")
        def field(name):
            for line in text.splitlines():
                if line.startswith(name):
                    return line.split(":", 1)[1].strip()
            return "?"
        kind = "CPU burn" if "cpu_resource" in path.name else "excessive wakeups"
        print(f"- **{path.name}** — {kind}; {field('Version')}; "
              f"{field('Date/Time')} → {field('End time')}")
        continue
    try:
        header, body = path.read_text(errors="replace").split("\n", 1)
        head = json.loads(header)
        payload = json.loads(body)
    except Exception:
        print(f"- **{path.name}** — unparsed")
        continue
    if "exception" in payload:
        exception = payload["exception"]
        signal = exception.get("signal", exception.get("type", "?"))
        # `termination.reason` does not exist; the useful trio is namespace +
        # indicator + reasons[0]. SIGABRT alone says nothing — "DYLD / Library
        # missing / Sparkle.framework" says everything.
        termination = payload.get("termination") or {}
        reason = " / ".join(filter(None, [
            termination.get("namespace"),
            termination.get("indicator"),
            (termination.get("reasons") or [""])[0],
        ]))
        for note in payload.get("asi") or {}:
            reason += f" | {note}: {'; '.join((payload['asi'][note] or [])[:1])}"
        alive = "?"
        try:
            from datetime import datetime
            fmt = "%Y-%m-%d %H:%M:%S.%f %z"
            started = datetime.strptime(payload["procLaunch"], fmt)
            ended = datetime.strptime(payload["captureTime"], fmt)
            alive = f"{(ended - started).total_seconds():.1f}s after launch"
        except Exception:
            pass
        print(f"- **{path.name}** — CRASH {signal} in {head.get('app_version','?')}; "
              f"died {alive}; faulting thread {payload.get('faultingThread')}; "
              f"{reason[:200]}")
    else:
        duration = payload.get("duration") or payload.get("durationInSeconds") or "?"
        print(f"- **{path.name}** — HANG/unresponsive, {duration}s, "
              f"{head.get('app_version','?')}")
INDEX
note "reports: $(( $(ls "$OUT/reports" 2>/dev/null | wc -l | tr -d ' ') - 1 )) file(s) from the last 14 days"

# ------------------------------------------------------- 5. daemon state dir
# roster.json is the live session table; tombstones.json records how sessions
# died, which is the first thing to read when "a session froze / vanished".
# pair.token is a live credential and is deliberately never copied.
for uid_dir in "${TMPDIR:-/tmp}"/fyolod-"$(id -u)" "${TMPDIR:-/tmp}"/fyolod-"$(id -u)"-dev "${XDG_RUNTIME_DIR:-}"/fyolod; do
    [ -d "$uid_dir" ] || continue
    dest="$OUT/daemon$(basename "$uid_dir" | sed 's/^fyolod-[0-9]*//')"
    mkdir -p "$dest"
    for file in roster.json tombstones.json host.id wss.bind; do
        [ -f "$uid_dir/$file" ] && cp "$uid_dir/$file" "$dest/" 2>/dev/null
    done
    ls -la "$uid_dir" >"$dest/listing.txt" 2>&1
    note "daemon state from $uid_dir (pair.token deliberately skipped)"
done

# ----------------------------------------------------- 6. app state + extras
for support in "$HOME/Library/Application Support/fyolo" "$HOME/Library/Application Support/fyolo-dev"; do
    [ -d "$support" ] || continue
    label=$(basename "$support")
    mkdir -p "$OUT/$label"
    ls -la "$support" >"$OUT/$label/listing.txt" 2>&1
    # state.json is the whole session tree — paths, names, layout. Copied because
    # layout bugs need it; redact.py scrubs it.
    [ -f "$support/state.json" ] && cp "$support/state.json" "$OUT/$label/" 2>/dev/null
    if [ -d "$support/hang_traces" ]; then
        mkdir -p "$OUT/$label/hang_traces"
        find "$support/hang_traces" -type f -mtime -14 -exec cp {} "$OUT/$label/hang_traces/" \; 2>/dev/null
    fi
done

# The Rust daemon's own log. It owns every PTY, so when the complaint is "a
# session froze" this is the process that was there.
for logs in "$HOME/Library/Logs/fyolo" "$HOME/Library/Logs/fyolo-dev" \
            "$HOME/.local/state/fyolo" "$HOME/.local/state/fyolo-dev"; do
    [ -d "$logs" ] || continue
    dest="$OUT/daemon-log-$(basename "$logs")"
    mkdir -p "$dest"
    find "$logs" -maxdepth 1 -type f -name 'fyolod.log*' -exec cp {} "$dest/" \; 2>/dev/null
    note "daemon log from $logs"
done

for extra in /tmp/fyolo-status.log /tmp/fyolo-dev.log; do
    [ -f "$extra" ] && tail -n 2000 "$extra" >"$OUT/$(basename "$extra")" 2>/dev/null
done

for config in "$HOME/.fyolo/settings.json" "$HOME/.fyolo-dev/settings.json"; do
    [ -f "$config" ] || continue
    cp "$config" "$OUT/settings-$(basename "$(dirname "$config")").json" 2>/dev/null
done

# ------------------------------------------------------------- 7. manifest
{
    echo "# Bundle manifest"
    echo
    find "$OUT" -type f | sed "s|^$OUT/||" | sort | while read -r f; do
        printf '%8s  %s\n' "$(du -h "$OUT/$f" | cut -f1)" "$f"
    done
} >"$OUT/manifest.md"

echo "$OUT"
