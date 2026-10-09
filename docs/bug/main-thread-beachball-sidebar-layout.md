---
title: Beachball family — sidebar layout stalls the main thread
status: active
type: bug
created: 2026-09-06
updated: 2026-09-06
related:
  - ../design/20260819-workspace-switch-latency.md
  - ../design/20260724-sidebar-scroll-performance.md
---

# Beachball family — sidebar layout stalls the main thread

> Why the release app beachballs on workspace switches and freezes typing in
> agent TUIs, with the evidence trail, the three root causes, and the fix plan.
> Investigated 2026-09-04 → 2026-09-06 on 0.49.0 (1881), macOS 26.6.2, M5.

## 0. The symptom

Two complaints, one thread:

1. Switching to a large workspace beachballs the whole app for seconds.
2. Typing into a TUI (Claude Code) intermittently freezes with a beachball.

Both are the **main thread doing seconds of SwiftUI/AppKit layout work**. The
daemon is healthy, the input path takes no contested lock, and nothing blocks
on I/O — every capture shows the main thread *busy*, never parked. The
2026-08-29 write-lock beachball (`InMemoryTerminalSession` header) is a
different, already-fixed bug.

## 1. The evidence

### What the OS recorded

`spindump` is macOS's beachball bookkeeper: it launches the moment any app
shows the spinning cursor and logs one line per event, visible with:

```sh
/usr/bin/log show --start "<time>" --info --debug \
  --predicate 'process == "spindump" AND eventMessage CONTAINS "fyolo"' \
  --style compact | grep -E "spin: start|slow hid response"
```

`slow hid response (N s)` means a keystroke or click sat unprocessed for N
seconds — the typing freeze, measured by the OS. Two bursts on 2026-09-04:

| Window | Events | Durations |
| --- | --- | --- |
| 18:43–18:46 (pid 64683) | 7 slow-HID + 3 spins | 4.0s, 1.2s, 1.8s, 0.6s, 0.8s, 2.9s, 4.2s |
| 20:14–20:16 (pid 82416, after relaunch) | 5 slow-HID + 2 spins | 4.9s, 0.8s, 2.1s, 2.2s, 0.6s |

Every line carries `not sampling due to conditions 0x4000…` — the OS throttled
itself and wrote **no stack captures** (no `.hang` files in DiagnosticReports).
So the system log proves *when* and *how long*; the *why* comes from fyolo's
own instrumentation and live `sample` runs.

### What fyolo's own trace recorded

The `Trace.workspace` spans from
[workspace-switch-latency](../design/20260819-workspace-switch-latency.md)
caught the worst stall end-to-end:

```
18:44:39.301  workspace switch to=Fyolo  elapsed_ms=1.27
18:44:47.856  (AppKit) WARNING: Application performed a reentrant operation
              in its NSTableView delegate. This warning will become an assert…
18:44:48.050  workspace column  elapsed_ms=8749.42
```

The store write is 1.27ms; the **column turn — the run-loop turn that lays out
the new sidebar List — is 8.75 seconds**, and AppKit's reentrancy warning fires
at its tail. Four `Publishing changes from within view updates is not allowed`
runtime issues landed in the same window (18:44:53).

Column-turn cost by workspace size, all on the same build:

| Switch target | Rows | Column turn |
| --- | --- | --- |
| Work | 15 | 145–273ms |
| Fyolo, warm (rows/surfaces cached) | 37 | 244ms–1573ms |
| Fyolo, cold (first visit) | 37 | **8749ms** |

2.4× the rows costs 32× the time: the cold mount is super-linear, which is what
the reentrant-delegate warning predicts — per-row work that re-enters table
layout instead of laying out once.

The other spindump events cluster at **selection changes** (the 4.9s slow-HID
ends exactly at a `selection change` line) and **split-divider drags** (the
2.1s/2.2s events sit inside a measure/`surface-at`/resync storm of ~50 log
lines in 600ms).

### What live samples show

`/usr/bin/sample` of the idle-but-working app (2026-09-04, agents running):
~10% of the main thread inside a 46-level-deep `_layoutSubtreeWithOldSize`
recursion, entered every frame via `stepTransactionFlush` →
`NSHostingView.layout()`, bottoming out in `WorkingIndicator.grid(phase:)`
with most leaf samples in `ColorBox.resolveHDR` → `NSAppearance` dynamic-color
resolution. A 30s sample on 2026-09-06 (no comets on screen) still shows
`NSAnimationContext.runAnimationGroup` wrapping hosted layout.

The daemon sample is all threads parked in `cond_wait` — not involved.

## 2. Root causes

### A. The sidebar column mounts rows reentrantly (the multi-second stalls)

The sidebar `List` is an `NSTableView`. Rows self-size against
`defaultMinListRowHeight = 1` (`SidebarView.swift:320`), and every session row
carries a `GeometryReader` that writes `rowHeight` state from inside the layout
pass (`SidebarView.swift:667–672`, feeding `SessionRowDropDelegate`). Mounting
N rows re-enters table layout per row instead of laying out once — the
super-linear cold-mount cost, the reentrant-delegate warning, and the
publishing-during-update warnings are all this shape. Warm switches are cheap
because rows and surfaces are cached; the 8.7s hit lands on the first visit to
a big workspace after launch.

### B. The working indicator still ticks on the animation clock (the constant drain)

[workspace-switch-latency](../design/20260819-workspace-switch-latency.md)
prescribed two fixes. Neither shipped. What shipped instead was the `Canvas`
rewrite of `WorkingIndicator` — a real improvement, but
`SessionStatus.swift:99` still reads:

```swift
TimelineView(.animation(minimumInterval: 1.0 / 30)) { … }
```

`.animation` is SwiftUI's animation-clock schedule; every tick is an animation
transaction that wraps `NSHostingView.layout()` in
`NSAnimationContext.runAnimationGroup` and walks the full-depth NSView tree —
30 times a second per working session, with per-dot appearance-color
resolution at the leaf. This is the background load that pushes keystroke
handling past spindump's 0.5s threshold whenever anything else (a selection
change, a divider drag, a resize resync) shares the run loop.

### C. Icon SVG paths are re-parsed on every layout pass (the multiplier)

The doc's item (3), also unshipped: `BrandIcons.swift:191, 295, 346` all build
`SVGPath(pathData)` inside `path(in:)` — measured at 171µs per parse. Paid on
every animated layout pass for every visible icon, and again for all 37 rows
during a cold column mount.

## 3. Fix plan, by value per line

1. **Schedule** — `TimelineView(.periodic(from: .now, by: 1.0/30))` in
   `SessionStatus.swift:99`, and resolve the tint once per appearance instead
   of per-dot `resolveHDR`. One line plus a small hoist; removes the
   `NSAnimationContext` wrapper from every tick.
2. **Icon path cache** — a static cache keyed by path string (plus the viewBox
   transform) at the three `SVGPath` sites in `BrandIcons.swift`.
3. **Row height measurement** — row height varies with settings (font,
   padding), not per row. Measure one prototype row and pass the height to
   `SessionRowDropDelegate`; delete the per-row `GeometryReader` writes. This
   is the reentrancy the NSTableView warning names.
4. **Re-profile the cold switch** after 1–3, per the latency doc's own
   sequencing: cold-switch into the 37-session workspace under
   `/usr/bin/sample` and read `workspace column elapsed_ms`. The
   `NSOutlineView` rewrite stays rejected unless the number still overruns.

## 3.5 Prior art online

The three causes are all known in the wild; none of the findings changes the
plan, two sharpen it:

- **`TimelineView(.animation)` churning AutoLayout on macOS is a confirmed,
  open Apple bug** — FB13810482, Apple Developer Forums thread 773682: a bare
  `TimelineView(.animation)` inside a hosting view makes macOS re-ask
  `sizeThatFits` continuously (iPad asks twice; macOS cycles forever). DTS
  offered no workaround. Moving off the `.animation` schedule is the fix the
  platform leaves us; `.periodic(from:by:)` is the documented alternative
  (`nilcoalescing.com/blog/TimelineViewInSwiftUI`).
- **`NSHostingView.sizingOptions` is a second lever for the same churn**: the
  default `[.minSize, .intrinsicContentSize, .maxSize]` re-asks the content's
  ideal size on *every view update* (WWDC22 "Use SwiftUI with AppKit";
  mjtsai.com / brian-webster.net on how NSHostingView sizes itself). The
  sidebar hosting view is pinned to the split item's size, so dropping
  `.intrinsicContentSize` stops each tick from invalidating constraints up
  the window.
- **macOS `List` eagerly builds every row** (it is not lazy like iOS — Apple
  forums 704778, 767585), and the reentrant-NSTableView-delegate warning is
  reported by others driving SwiftUI tables with dynamic content. The
  community answers are exactly our fix 3's direction: **uniform row heights**
  (kean.blog "…But Not NSTableView": macOS must know every cell's height for
  the scroll indicator, so self-sizing rows fight the platform; his
  static-height rewrite made a 150k-row list "blazing fast"). The full
  `NSTableView` rewrite stays rejected per the latency doc; uniform heights we
  can have without it.
- **`GeometryReader` + `onChange` for size tracking is the deprecated shape**
  of what we do per-row; the modern replacement is the `onGeometryChange`
  modifier (Xcode 16, back-deployed to macOS 13), which exists precisely to
  observe geometry without mutating state mid-update
  (swiftwithmajid.com "Tracking geometry changes in SwiftUI"). Fix 3 removes
  the per-row measurement entirely, which is better still.

Reference code, per fix:

- `sizingOptions = []`: fyolo's own detail pane already does it, with the
  full rationale in the comment (`App.swift:644–655`) — the sidebar hosting
  controller at `App.swift:623` is the one that never got it. Same move in
  the wild: cmux hosts SwiftUI session rows in recycled `NSTableCellView`s
  with `hostingView.sizingOptions = []` and the comment "the controller owns
  row heights, so visible cells never negotiate intrinsic SwiftUI size during
  an AppKit table layout pass"
  (github.com/manaflow-ai/cmux, `Sources/SessionIndexTableCellView.swift`).
- `.periodic` indicator: Klee's `ThinkingIndicator` drives its dots from
  `TimelineView(.periodic(from: .now, by: 0.3))` with the phase computed from
  the tick date (github.com/signerlabs/Klee,
  `Klee/View/ThinkingIndicator.swift`) — the same shape `WorkingIndicator`
  needs at `1.0/30`.
- Icon path cache: OpenUsage's `ProviderIconShape` stores `parsedPath` and
  `bounds` on the mark — parsed once — and `path(in:)` only applies the
  scale/translate transform (github.com/robinebers/openusage,
  `Sources/OpenUsage/Support/ProviderIconShape.swift`). `HugeIconShape`
  should hold the same two cached values instead of re-running `SVGPath`.

## 4. Verification

Everything needed is already instrumented — before/after is one `log show`
away:

- `workspace column elapsed_ms` on subsystem `sh.fyolo.app`, category `app`
  (cold switch into the biggest workspace is the number that matters).
- spindump's `slow hid response` lines for fyolo (query in §1) over a normal
  working session — the target is zero above threshold.
- An idle `sample` with two working sessions: `NSHostingView.layout()` share
  of the main thread, compared against the ~10% baseline recorded here.

## 5. What this is not

- Not the daemon: `fyolod` samples idle throughout.
- Not the PTY write path: `FyolodSessionLink` stamps and hands off to its
  work queue; `outputLock` is never taken on the main thread.
- Not the agent CLI: the stalls fire on workspace switches with no agent
  involvement.
- Not the 2026-08-29 mailbox deadlock: that was a blocked main thread; this
  one is busy.
