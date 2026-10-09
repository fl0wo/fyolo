---
title: Workspace switch latency
status: in-review
type: design
created: 2026-08-19
updated: 2026-08-19
related:
  - 20260724-sidebar-scroll-performance.md
---

# Workspace switch latency

> The store write that changes workspace is 0.2–0.4 ms. The hitch is the SwiftUI
> display cycle that follows it (33–100 ms to the settle turn) plus a main
> thread that is already spending ~11% of every idle second inside
> `NSHostingView.layout()` wrapped in `NSAnimationContext`. Instant means that
> column layout drops under one 60 Hz frame and the 30 Hz animated layout stops
> competing with it.

Measured on 2026-08-19 against `docs/switch-profile` at `4a22d88` (same commit
as `feat/workspaces`), running as the live `fyolo-dev` host
(`/Users/yuanjiwei/Documents/GitHub/fyolo-worktrees/workspaces/fyolo-dev.app`,
pid 59135). Screen Recording is not granted on this machine, so this pass did
not look at pixels. The File ▸ Workspace menu is reachable from System Events
and is what produced the switch numbers. A trackpad swipe was not driven. It
calls the same `WorkspaceSpaces.select`.

## Already shipped, not redone

| Work | Where |
| --- | --- |
| `locate()` is an O(1) slot index | `SessionSlotIndex` |
| Per-row menu / tombstone / device / status hoisted or deferred | sidebar rows |
| Terminals cached across rebuilds | `SurfaceCache` |
| File tree cached per root | `FileTreeCache` |
| Session / inspector / roster half deferred one run-loop turn | `FyoloStore+Workspaces.finishArriving`, `workspaceArrival` |
| Scope commit in a `Transaction` with `disablesAnimations` | `switchToWorkspace` |
| Device roster one fetch per switch; identical reply is a no-op | `refreshDeviceSessions` / `applyRoster` |

The 0.7 ms switch figure already in circulation is this commit path. It is
real. It is also the wrong number for "why does this feel blocked."

## How the switch is timed

`WorkspaceSpaces.select` and `switchToWorkspace` both emit `Trace.workspace`
`workspace switch`. `finishArriving` emits `workspace settle`. Those are
`os_signpost` intervals and `elapsed_ms` lines on subsystem `sh.fyolo.app.dev`,
category `app`.

This pass adds two more spans and does not change control flow:

- `workspace column` — begun after the scope write, ended at the start of
  `finishArriving`. That is the rest of the current run-loop turn: SwiftUI
  applying `currentWorkspaceID`, the hosted sidebar laying out, the display
  cycle committing. The switch span cannot see this work. It runs after
  `switchToWorkspace` returns.
- `workspace selection` / `workspace device` — the two pieces inside settle.

The live host at measurement time was `4a22d88`, which does not yet carry the
column span. Column time below is the wall gap from the switch log line to the
settle log line on the same click. The instrumented binary is built on this
branch so the next run prints that gap as `workspace column elapsed_ms`.

## Finding 1 — idle CPU is not a workspace invention

`WorkingIndicator` on `origin/main` (`615f49c`) is the same type as on this
branch: `TimelineView(.animation(minimumInterval: 1.0 / 30))` in
`Shared/Sources/FyoloShared/SessionStatus.swift`. `HugeIconShape.path(in:)`
reparses `SVGPath(icon.pathData)` on every layout in both trees
(`BrandIcons.swift`).

Conditions for the this-branch numbers: three workspaces (Sessions, work,
ukvps), current scope Sessions (4 loose terminals + 1 chat), two sessions
`.working` (this one and its parent), two live `fyolod-read` / ghostty
renderer pairs. A leftover `before.app` (same bundle id, 12 hours old, ~18–28%
`ps` CPU) was killed first so it would stop sharing the `.dev` identity.

`top -l 12 -s 1 -pid 59135` after that kill, 11 usable 1-second samples:

```
34.8  42.5  43.0  30.2  9.9  50.0  40.3  25.5  45.3  17.3  41.2
```

Median 40.3%. Range 9.9–50.0%. `ps -o %cpu` at +5m42s had decayed to 22.1%
and is the number that misleads. The cited 3–22% was one working session; this
host had two, plus two Metal renderers.

`/usr/bin/sample` 8 s, 1 ms, pid 59135, 6399 main-thread samples:

| Stack | Samples | Share of main thread |
| --- | --- | --- |
| `NSHostingView.layout()` | 712 | 11.1% |
| of those, inside `+[NSAnimationContext runAnimationGroup:]` | 706 | 11.0% |
| `HugeIconShape.path(in:)` (inside that layout) | 148 | 2.3% |
| `WorkingIndicator` / `TimelineView` fyolo symbols | 0 | inlined into SwiftUI |

712 ms of layout over 8 s is 89 ms/s. At 30 layout passes per second that is
~3 ms per pass. `WorkingIndicator` is capped at 30 Hz. The rates match.

origin/main (`615f49c`, binary from `/tmp/fyolo-main-idle/fyolo-dev.app`)
was launched as a second process with `FYOLO_CHANNEL=idlemain` so it could
not take this host's sockets or `~/.fyolo-dev`. Seeded from
`state.json.pre-rename` (10 projects, 24 sessions). Those sessions were
idle in the file and this process did not mark any of them `.working`.
`open` was not used: the bundle id is still `sh.fyolo.app.dev`.

`top -l 12 -s 1` on that pid:

```
24.5  3.9  2.8  56.5  97.8  26.6  18.8  32.4  10.6  13.7  17.5
```

The 24.5% is launch. 3.9 / 2.8% is the populated sidebar with no comet.
56–98% is origin/main restoring the 24 sessions (thread count 16 → 21,
RSS 224 M → 315 M). The last three samples, after that storm, are
10.6 / 13.7 / 17.5% — live PTY/renderer cost, still no
`WorkingIndicator`. A 5 s `sample` of that process had 20
`NSHostingView.layout()` mentions and 8 `NSAnimationContext` mentions,
against 712 / 706 on this branch with two comets.

While origin/main was frontmost the host dropped to 3.0–14.0% on a 5 × 1 s
`top` (median 8.1%). The 40% this-branch series is the key window. The
backgrounded window does not pay the same display-cycle tax.

The workspace refactor adds `WorkspaceDots` and a toolbar switcher. Those
views do not tick on `TimelineView`. They are not the 30 Hz layout. The
idle tax tracks a working comet, and that comet is on `origin/main`.

A 20 s sample taken earlier (no `Trace.workspace` switch line, ~4.9 s in this
same `stepTransactionFlush` → `NSDisplayCycleFlush` → `NSHostingView.layout()`
→ `NSAnimationContext` chain) was idle cost. This 8 s sample is the same
chain with counts.

## Finding 2 — the idle animation driver

The driver is `WorkingIndicator`'s `TimelineView(.animation(minimumInterval: 1.0 / 30))`.
`.animation` is SwiftUI's animation-clock schedule, not a name for the comet.
Each tick is an animation transaction. `NSHostingView.layout()` wraps that
transaction in `NSAnimationContext.runAnimationGroup`. The hosted sidebar
tree is laid out again. `HugeIconShape` is what that layout spends 2.3% of
the main thread on, because `path(in:)` builds a fresh `SVGPath` from the
icon's path string every time.

The comet itself does not invalidate layout. `WorkingIndicator.dot` uses
`scaleEffect` and `opacity` for that reason (comment on the type). The
schedule still wraps the hosting view.

A standalone copy of the `SVGPath` parser, `-O`, 5 000 iterations of a real
575-character Hugeicons path plus `boundingBoxOfPath`: **171 µs per call**.
Sixteen icons at 30 Hz would be 82 ms/s if every pass re-parsed every icon.
The sample's 148 hits in 8 s is lower (fewer on-screen marks, cheaper paths).
It is still paid on every animated layout, including the one a workspace
switch lands in.

`WorkspaceDots` attaches `.animation(.snappy(duration: 0.24, extraBounce: 0.12),
value: store.currentWorkspaceID)`. That fires when the scope changes, not at
idle. `switchToWorkspace` already disables animations on the commit so this
capsule does not drag the List through an animated relayout. The idle sample
is not this.

Menu-bar and Session-menu comet timers (15 Hz, `NSEventTrackingRunLoopMode`)
run only while those menus are open. They were not.

## Finding 3 — where a real switch frame goes

Four File ▸ Workspace clicks, current tree, no `sample` attached. Two
`workspace switch` lines per click: the inner span in `switchToWorkspace` and
the outer `WorkspaceSpaces.select` wrapper. They agree to 0.02 ms.

| Click | Direction | switch (ms) | column gap (ms) | settle (ms) | selection (ms) | persist (ms) | focus log (ms after switch) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Sessions → ukvps | 0.27 / 0.28 | **89** | 0.51 | 0.45 | 0.70 | 352 |
| 2 | ukvps → Sessions | 0.29 / 0.31 | **46** | 0.42 | 0.38 | 0.43 | 938 |
| 3 | Sessions → ukvps | 0.39 / 0.40 | **100** | 0.50 | 0.42 | 0.77 | 410 |
| 4 | ukvps → Sessions | 0.20 / 0.22 | **33** | 0.45 | 0.40 | 0.49 | 94 |

Column gap = settle timestamp − switch timestamp. That is one `DispatchQueue.main.async`
turn: the display cycle that paints the new List.

Going to ukvps (8 loose terminals, device fallback) costs 89–100 ms of that
turn. Going to Sessions (5 rows) costs 33–46 ms. At 60 Hz those are 2–6
frames of hosted layout after a 0.3 ms store write.

Settle Swift is 0.42–0.51 ms and already includes `selectedSessionID`'s
`didSet` (`applyInspectorState`, `enterDevice` / `switchToDevice`,
`persistSoon`). The inspector restore writes on the order of a dozen
`@Published` properties. That is cheap in Swift. The views those publishes
invalidate run after `finishArriving` returns, on the settle turn. They are
a second layout, not the column one.

Roster, already coalesced:

- First ukvps ask: fetch 41 ms off the main thread, apply 0.07 ms. A second
  ask in the same settle is `roster coalesced` at 0.00 ms.
- Repeat ukvps: fetch 35 ms, `roster unchanged` 0.05 ms, apply 0.05 ms.
- unix (This Mac) fetch 0.9–1.4 ms. One round-trip logged 891 ms; the fetch
  itself was 1.38 ms. The reply sat behind a busy main thread. The next unix
  round-trip was 61 ms.

`moved terminal focus [selection-changed]` is
`TerminalFocusDriver.makeFirstResponder` succeeding. The surface is a
`SurfaceCache` hit. The delay is retries until that `NSView` is in the key
window after SwiftUI mounts it (`TerminalPane` `onChange(of: isSelected)` →
`requestFocus(.selectionChanged)`, then `retryMove`). 94 ms on the cheap
Sessions return, 352–410 ms onto ukvps. The 938 ms line is the same event as
the 891 ms unix roster reply: main thread was not servicing the focus retry
queue.

A 4 s `sample` taken *during* two of these clicks inflated the switch span
to 2.18 ms and the column gap to 111 ms. Do not profile the switch with
`sample` attached and then trust the `elapsed_ms` from that window.

What a human still has to look at: whether 33 ms of column layout reads as a
hitch on this display, and whether the 94–410 ms focus delay is the part
that feels like "the terminal hasn't arrived yet." This machine cannot
screenshot.

## What "instant" is

A 60 Hz frame is 16.7 ms. Instant here is:

1. **Column turn ≤ 16 ms.** The List that `currentWorkspaceID` rebuilds has to
   commit in the same display cycle as the click, without borrowing the next
   two to six frames. ukvps at 89–100 ms is the case that fails this.
2. **Idle layout stops being an animation transaction.** Replace
   `TimelineView(.animation(…))` with a schedule that is not the animation
   clock (`TimelineView(.periodic)`, or a phase driven from outside the
   hosted tree). The comet can keep moving. It must not wrap
   `NSHostingView.layout()` in `NSAnimationContext` 30 times a second. That
   is 89 ms/s of main thread the switch currently shares the run loop with.
3. **Icon paths are not parsed during that layout.** Cache `CGPath` per
   `HugeIcon` (and the ink-normalised transform) on `HugeIconShape`. 171 µs
   per parse is optional at 1 Hz and not optional at 30 Hz × N marks.
4. **Settle stays on the next turn**, which it already does. Do not pull
   selection / inspector / device / focus back into the column turn. That is
   how a 0.3 ms switch became a 0.7 ms number that still felt blocked.
5. **Focus retry should not be the user's "it landed" signal.** 94–410 ms
   after the click is when the cached surface becomes first responder. If
   the column painted at 16 ms and the caret arrives 400 ms later, the
   switch still feels late. Worth its own measurement once (2) is gone,
   because today's 30 Hz layout is also what starves the retry.

Persist at +400 ms (0.43–0.77 ms) is not on the path. Leave it.

## Rejected

- **Treat the 0.3–0.7 ms switch span as the problem.** It is the store write
  and the `Transaction`. The hitch is the display cycle after it. Speeding
  up `locate()` again, or coalescing the roster again, cannot move a 33–100
  ms `NSHostingView.layout()`.
- **Pull settle back into the switch.** That is the shape `2145c1b` removed.
  Selection + `applyInspectorState` + `switchToDevice` are a second full
  store invalidation. Putting them in the column turn is how a fast scope
  change reads as a slow one.
- **Re-enable implicit animation on the commit so the capsule can slide in
  the same transaction as the List.** `4a22d88` exists because a profile of
  that path was `NSHostingView.layout()` inside
  `NSAnimationContext.runAnimationGroup`. The dots can animate from their
  own `matchedGeometryEffect` if they must. They cannot be allowed to tag
  the row replacement.
- **Rewrite the sidebar as `NSOutlineView`.** [Sidebar scroll
  performance](20260724-sidebar-scroll-performance.md) already rejected
  migrating the whole store to `@Observable` for a smaller reason. An AppKit
  rewrite would fix hosting-view layout at the cost of the row work that
  file records, and it is not required to stop `TimelineView.animation` or
  to cache a path.
- **Snapshot the outgoing column to a bitmap and cross-fade.** That hides a
  100 ms layout behind a fade. It does not remove it. The next switch pays
  it again, and the idle 30 Hz layout keeps running under the bitmap.
- **Keep every workspace's `List` mounted and hide the inactive ones.** Three
  workspaces × full row trees, all still under one `NSHostingView`, all
  still laid out when `TimelineView.animation` ticks. Memory for a problem
  that is the animation schedule.
- **Drop the comet while a session is working.** The mark is the status.
  Reduce Motion already holds one frame. The fix is the schedule, not the
  pixels.
- **Profile with `ps -o %cpu` or with `sample` attached to the click.**
  `ps` is a decaying average (22% next to a 40% `top` median). `sample` on
  the click moved switch from 0.3 ms to 2.2 ms and the column gap to 111 ms.
- **Redo `SurfaceCache`, `FileTreeCache`, `SessionSlotIndex`, roster
  coalescing, or `disablesAnimations`.** They are in the table at the top.
  None of them is the 33–100 ms column turn or the 30 Hz animation layout.
- **Blame `HugeIconShape` as the driver.** It is 2.3% of the idle main
  thread, inside a layout it did not start. Caching the path is the right
  follow-up once the schedule is not `.animation`. It is not the first cut.

## Instrumentation left on the branch

`FyoloStore+Workspaces.swift` only: `workspace column` around the deferred
turn, `workspace selection` and `workspace device` inside settle. No
control-flow change. Read them with:

```
log stream --predicate 'subsystem == "sh.fyolo.app.dev" && category == "app"' --level info
```

A click should print `workspace switch`, then `workspace column` (the number
this pass inferred from timestamps), then `workspace settle` / `workspace
selection` / `workspace device`.

## What this does not decide

Which of (2) and (3) to ship first. (2) is the idle tax and the thing a
switch shares the run loop with. (3) is a one-line cache on a `Shape` that
is already paid on every layout, switch or not. (1) is "is the List itself
too big for one frame once the animation wrapper is gone." Measure (1)
again after (2). Today's 89–100 ms includes the wrapper.

A same-conditions A/B with *one working session as the key window* on
origin/main was not taken. Making a session `.working` on that process
needed a click this pass did not have. The 2.8–3.9% (no comet) versus
9.9–50% (two comets, key window) pair, plus the identical
`TimelineView(.animation)` source, is the comparison that exists.
