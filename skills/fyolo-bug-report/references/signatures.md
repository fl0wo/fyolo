# Known signatures

Every entry here was a real fyolo bug. Match the artifact against this table
before writing a fresh diagnosis — most "fyolo is frozen" reports land on one of
these, and naming the prior bug is worth more to the issue than a new theory.

A signature that matches is a hypothesis, not a verdict. Say which artifact
supports it and what would disprove it.

## How to read a `sample`

The whole report is one indented call tree per thread, with a sample count on the
left. Everything hangs off one question: **where is the main thread?**

```
853 Thread_3914307: Main Thread   DispatchQueue_<multiple>
```

- `853` out of 853 samples in `mach_msg2_trap` under `__CFRunLoopServiceMachPort`
  — the app is **idle and healthy**, parked waiting for events. A beachball
  report with this stack means the freeze is elsewhere: the GPU, the daemon, or
  the user's own agent process filling the PTY.
- Most samples under `CA::Transaction::commit` or SwiftUI's update machinery —
  the main thread is **doing layout/render work every frame**. Look for an
  animation driving continuous invalidation.
- Any main-thread sample inside `psynch_mutexwait`, `__ulock_wait`,
  `_dispatch_...wait`, or a bare `write`/`read` — the main thread is **blocked**.
  Read the frames directly above it to find who holds the lock, and check the
  other threads for the holder.

The `Binary Images` table at the bottom identifies the exact framework and
libghostty build; keep it. `redact.py` deliberately leaves its version columns
alone.

## What macOS recorded on its own

The OS keeps its own account of a crash or a stall, and it is often better than
anything fyolo logged — a beachball leaves nothing in the app's own log by
definition, because the thread that would write it is the thread that is stuck.
`collect.sh` gathers all of it into `reports/` and writes `reports/index.md`, one
line per report. Read the index first, then open only what it points at.

**`*.ips` with an `exception` key — a crash.** Four fields carry the whole story:

- `exception.signal` — `SIGABRT`, `SIGSEGV`, `SIGKILL`.
- `termination.namespace` / `indicator` / `reasons[0]` — the *why*. There is no
  `termination.reason`; reading for it returns nothing and makes an informative
  report look empty. `DYLD / Library missing / Sparkle.framework` is a packaging
  bug; `SIGNAL / Abort trap: 6` is a Swift trap or an assertion.
- `asi` (Application Specific Information) — the abort message, when there is one.
- Time from `procLaunch` to `captureTime`. Under a second means it died at
  launch: look at linking, signing, and bundle layout, not at the feature the
  user was using.

**`*.ips` without an `exception` key — an unresponsiveness report.** macOS only
writes these when hang reporting is on for the machine, so their absence is not
evidence that the app was responsive.

**`*.cpu_resource.diag` — the OS caught the process burning CPU.** This is the
highest-value artifact for a beachball nobody sampled in time: the OS took
Microstackshots throughout the burn, so the file already contains the stack the
app was spinning in, plus the exact version and the window it covered. Read it
the same way as a `sample` — find the heaviest main-thread stack.

**`*.wakeups_resource.diag` — excessive wakeups.** A timer or polling loop firing
far more often than it should. Shows up as an app that is idle but never lets the
machine sleep.

**The system side of the unified log** (`unified-log-system.txt`) is where a death
the app could not report appears: `WindowServer` marking the app unresponsive,
the kernel's jetsam killing it under memory pressure, code-signing rejections.
fyolo's own subsystem cannot log its own kill.

**When the whole UI is frozen, not just fyolo,** the per-process artifacts will
not show it. Ask the user to run `sudo spindump 10 -file /tmp/spindump.txt` — it
needs a password, so `collect.sh` never attempts it — and read which process
everything else is blocked on.

## The prior bugs

| What you see | Where it shows | What it was |
| --- | --- | --- |
| Beachball, main thread blocked in `write` under a surface lock | `sample` main thread | A blocking PTY write held under the surface lock. PTY writes must stay non-blocking. |
| Beachball, high idle CPU, main thread deep in `CA::Transaction::commit` | `sample` main thread + `top` | An indeterminate `WorkingIndicator` animating `scaleEffect` at 30 Hz, invalidating layout forever. |
| App freezes minutes after the display sleeps; memory climbs; repeated renderer errors | `unified-log-system.txt`, memory in `environment.md` | Renderer OOM retry storm after display sleep — the retry loop had no ceiling. |
| Hidden panes burn CPU/GPU with the window in the background | `sample` shows renderer threads busy on non-visible surfaces | Occluded panes kept live renderers. The fix was `setSurfaceVisible`, never raw `set_occlusion`. |
| A vertical seam / torn frame across a pane | screenshot, not a log | Ghostty's swap chain re-using the on-screen IOSurface when main is late. Fixed in the fork by present backpressure. |
| Terminal never reflows on window resize | reproduction, not a log | The PTY was spawned with `posix_spawn` instead of `forkpty`. See `docs/bug/terminal-resize-no-reflow-HANDOFF.md`. |
| New terminal opens with a hollow cursor and beeps until clicked | reproduction | Focus race in the surface wrapper. Three separate variants — see the three `docs/bug/terminal-focus-loss-*.md`. |
| Agent welcome banner frozen into a narrow column | screenshot | Session opened against a stale narrow grid. `docs/bug/terminal-narrow-grid-frozen-banner-on-open.md`. |
| A stray `%` at the end of the shell's first line | screenshot | zsh's `PROMPT_SP` reflow against the host grid at spawn. |
| Phone lists sessions but the terminal says "unauthorized" | companion logs | The phone resized before auth completed — **not** a stale tunnel URL. `docs/bug/companion-terminal-unauthorized-over-tunnel.md`. |
| iOS app dies on reopening a session (`0x8BADF00D`) | iOS crash report | Renderer mailbox blocked on `cond_not_full`. |
| iOS app dies switching sessions (`EXC_GUARD`, `close(fd 0)`) | iOS crash report | Surface teardown closed descriptor 0. |
| iOS "non-functional panel" message | iOS console | libghostty's IO thread died — not a GPU failure. |

## Where the evidence is thin

Two gaps to state honestly in an issue rather than paper over:

- **The Rust daemon keeps its own log**, at `~/Library/Logs/fyolo/fyolod.log`
  (`fyolo-dev` for the dev channel), collected into `daemon-log-*/`. It holds
  one `--- fyolod <version> starting, pid N ---` line per daemon run followed by
  everything that run printed, including a panic message. Read it whenever the
  complaint is about a session rather than the window: `fyolod` owns the PTYs.
  Note the daemon writes it only when its stderr goes to `/dev/null`, which is
  how the app and launchd start it — a daemon someone ran by hand in a terminal
  printed to that terminal instead, and left no file.

  Builds before this existed have no such log at all, so an old report legitimately
  has nothing here. Check `environment.md` for the version before concluding the
  daemon was silent.
- **`log show` drops `.debug` and `.info` unless you ask.** `collect.sh` passes
  `--info --debug`; a hand-run `log show` without them looks empty and is not
  evidence of a quiet app.

## Deciding whether it is even fyolo

The terminal hosts someone else's process. Before filing against fyolo, rule out
the obvious alternative: an agent CLI that is itself wedged.

- `environment.md` lists the agent CLI versions.
- A `sample` of the app showing a healthy idle main thread, while the *agent*
  process is pinning a core, is an agent bug.
- `tombstones.json` records how sessions ended. A session whose child exited on
  its own is not a fyolo hang.
