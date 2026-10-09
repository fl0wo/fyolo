---
title: Instant view switching — prior art and technique
status: draft
type: design
created: 2026-08-19
updated: 2026-08-19
related:
  - 20260724-sidebar-scroll-performance.md
  - 20260805-fyolod-device-architecture.md
---

# Design: Instant view switching

> What makes a view switch instant in a SwiftUI + AppKit + libghostty app, measured rather than assumed, and what the same problem looks like in unpeel, zed, and codex.

## The question

Switching a session, a workspace, or an inspector tab should feel like the new
view was always there. Today it does not, and a profile of Fyolo's main thread
puts ~4.9s of a 20-second window inside `stepTransactionFlush` →
`NSDisplayCycleFlush` → `NSView.layoutSubtreeIfNeeded` → `NSHostingView.layout()`
→ `NSAnimationContext.runAnimationGroup`, with no Fyolo symbols underneath. The
cost is SwiftUI laying out the hosted tree inside an animation, not Fyolo's own
body code.

That framing rules out most of the usual advice. You cannot make a switch fast by
writing a faster `body` if `body` is not where the time goes. This document
establishes what SwiftUI actually skips, reads how three comparable projects
solve the same problem, and says which shape Fyolo should adopt — and, at
length, which shapes it should not.

A sibling effort is profiling Fyolo's own switch path. This document
deliberately stays off that ground: everything below is either a measurement of
the framework in isolation, or something read in another project's source.

## Part 1 — What SwiftUI actually skips

Measured, not recalled. The probes are standalone AppKit binaries in
`switchprobe/` under this session's scratchpad: an `NSHostingView` over a
`CountingLayout` (a custom `Layout` that tallies every `sizeThatFits` and
`placeSubviews` call) with leaves that tally every `body` evaluation. The runloop
is spun manually so layout and display are flushed at known points. macOS 26.5
(25F71), Apple M5, Swift 6.3.1, `-O`.

### Hiding a subtree skips nothing

20 leaves, 30 state changes — 600 body evaluations if nothing is skipped:

| subtree treatment | body evaluations | `sizeThatFits` | `placeSubviews` |
| --- | --- | --- | --- |
| visible | 600 | 90 | 60 |
| `.hidden()` | 600 | 90 | 60 |
| `.opacity(0)` | 600 | 90 | 60 |
| `.frame(width: 0, height: 0)` | 600 | 30 | 60 |
| removed with `if` | 0 | 0 | 0 |

`.hidden()` and `.opacity(0)` are byte-identical to visible. They are render-time
modifiers; the view is still in the tree, its body still runs, its children are
still measured and placed. A zero frame drops two thirds of the *measurement*
calls, because a fixed frame answers the parent's size question without
re-proposing to the child — but the children are still evaluated and still
placed. Only removal skips work, and removal skips all of it.

### Rasterizing modifiers skip nothing either

300 rows, one state change, median of 11:

| modifier | wall | body evaluations |
| --- | --- | --- |
| none | 17.5ms | 300 |
| `.drawingGroup()` | 16.6ms | 300 |
| `.compositingGroup()` | 17.8ms | 300 |

Both are compositor-level instructions about how the result is *drawn*. Neither
is a cache, and neither knows anything about whether the content changed.

### The real trade: switch cost against steady-state cost

Two columns of 300 rows, A/B switched. "Removal" is an `if`/`else`;
"keep-alive" holds both columns in a `ZStack` and changes only an opacity value,
with no branch anywhere (branching on a modifier swaps view identity and rebuilds
the subtree — measured separately below).

| | cost of the switch | body evals per switch | cost of one unrelated update | body evals per update |
| --- | --- | --- | --- | --- |
| removal | 31.5ms | 300 | 19.7ms | 300 |
| keep-alive by opacity | 3.1ms | 0 | 36.7ms | 600 |

This is the whole problem in one table. Keeping the other column alive makes the
switch about ten times cheaper and costs nothing at switch time — and then taxes
**every subsequent update** by the full price of every retained column. Two
columns, exactly 2×. Ten retained sessions, 10×. An app where an agent's output,
a status flip, and a title spinner all write state several times a second pays
that tax continuously, which is what an unexplained idle CPU floor looks like
from the outside.

Neither column of that table is the answer. The answer is to make the retained
thing invisible to SwiftUI entirely — Part 3.

### Two traps found on the way

**Branching on a modifier destroys the subtree.** An early probe wrote
keep-alive as `@ViewBuilder func hidden(_ on: Bool) { if on { self.hidden() } else { self } }`.
That switch cost 59.6ms — worse than removal — and produced 300 `onAppear` and
300 `onDisappear` calls *per column per switch*: both columns were torn down and
rebuilt every time. The `if` inside the builder changes the view's structural
identity, so SwiftUI treats the result as a different view. unpeel hit the same
thing and documented it on its selected-row background
(`Views/SidebarView.swift:3330-3344`): the glass effect is applied as a
`.background` rather than by branching around the row, because branching
"swaps the row's view identity on every selection change, re-inserting the row
content with a visible fade".

**Animation makes a switch's cost hard to measure and easy to misread.** A probe
that pumped the runloop for a fixed number of turns reported `withAnimation` as
20× cheaper than a plain switch. It is not cheaper; the work simply moved outside
the sampling window. Any measurement of an animated transition has to run to
quiescence, and any *profile* of one will attribute the work to whatever runs it
later — which is exactly the shape of the `NSAnimationContext.runAnimationGroup`
frame in Fyolo's profile.

## Part 2 — Prior art

### unpeel — the same stack, further along

`unpeel-com/unpeel` is Swift + AppKit over libghostty, 293 Swift files under
`apps/native/UnpeelNative`. The public repository 404s as of 2026-08-19; the
reading below is from a clone taken on 2026-08-18 at `d017f75`. It has no file
browser, so it says nothing about the file-tree half of a Fyolo switch.

Its switch architecture, in the order the cost shows up:

**Panes are retained AppKit views, never SwiftUI subtrees.** `SurfaceCache.swift`
keeps one pane per session id, created on first selection or on pre-warm, capped
at 8 by a most-recently-shown LRU. The file's own header states the reason:
surfaces are "KEPT ALIVE and swapped in/out of the view hierarchy — never
destroyed on switch". The webview app it replaced could only afford to retain 2;
the native one affords 8 because a detached pane costs approximately nothing.

**Teardown is deferred, staggered, and revocable.** `SurfaceCache.drop` removes
the pane from the map immediately, then frees the Ghostty surface on a later
main-loop turn spaced `0.1s × pendingTeardowns` apart. The comment says why:
`prune` runs inside SwiftUI's publish/layout path, and synchronous surface
destruction there froze the app. Each queued teardown carries a token, so a pane
reclaimed before its turn arrives cancels the eviction instead of spawning a
second attach client. The remote pane cache does the same thing more simply
(`GhosttyBridge.swift:1770-1786`), and for the same stated reason: move Metal
teardown out of the layout pass that decided to prune.

**The swap is synchronous, and so is the first frame.** `TerminalHostView`
(`Views/TerminalArea.swift:704-976`) is an `NSViewRepresentable` over a
`SwapContainer`. On a warm switch it detaches the old pane, adds the new one, and
then — inside the same `updateNSView` call — focuses it and forces a synchronous
draw. The comment is the most useful sentence in the file: without the immediate
draw, the first composited frame is the pane's stale pre-detach drawable, and the
cursor pops from hollow to filled a frame later; "together they read as switch
lag". The switch was already instant. What was not instant was the first *correct*
frame.

**Cold switches paint the background first and build second.** When no pane
exists, the same method paints the terminal background in the current
transaction, records a pending session id, and creates the expensive pane on the
next main-loop turn — with a guard that drops the deferred work if selection
moved on. Fyolo's own "defer the session/inspector half one runloop turn behind
the column paint" is the same move, arrived at independently.

**Nothing about the swap animates, on purpose.** `ContentArea` uses
`.transition(.identity)` on both branches plus `.animation(nil, value:)` on the
container. The header explains the root cause of an earlier bug: animating
opacity or frame across a `CAMetalLayer` snapshots the layer, blacks the drawable
for a frame, and re-composites vibrancy. Their old "settings blink" was an
animation, not a slow switch.

**Pre-warming is intent-driven and rate-limited.** A sidebar row fires
`prewarmSession` only after a 450ms pointer dwell (`Views/SidebarView.swift:2462`,
`2608-2620`), with the comment that keeping the trigger well behind visual hover
stops a fast sweep through a long list from mounting panes. The session you just
left is also pre-warmed one runloop turn later, because A↔B ping-pong is the most
common next switch (`UnpeelStore.swift:274-284`). The cap is 3.

**Pre-warmed panes are mounted hidden but must keep ticking.** `WarmPaneHostView`
mounts them in a hidden container — being in the window is what lets the surface
build and spawn its client. Two constraints are documented on top of that. Only
**one brand-new pane may be created per update pass**, because surface creation is
synchronous main-thread work (process spawn plus Metal setup) and a hover sweep
would otherwise stall a frame with several. And the hidden panes must *not* be
paused via `setSurfaceVisible(false)`: that suspends the wakeup→tick loop, a
surface that never ticks while its client floods the replay wedges its IO, and the
next synchronous surface call from the main thread deadlocks
(`GhosttyBridge.swift:401-407`). Hidden-but-ticking is the safe state.

**Hidden panes stop tracking size during a live resize.** `WarmPaneContainerView`
frames its children by hand rather than with edge constraints, and skips the sync
while `window.inLiveResize`, with one catch-up pass at `viewDidEndLiveResize`.
Otherwise every hidden pane runs a full grid and PTY resize — socket roundtrip,
host reflow, TUI repaint — on every drag frame, multiplying the visible pane's
cost by the pre-warm count.

**The sidebar memoizes its own row lists.** `UnpeelStore.sidebarLists` caches the
per-project ordered lists and is invalidated explicitly, because every store
publish re-ran each visible project's body, which asked for both lists —
"ordering plus a UserDefaults read per project per render pass"
(`UnpeelStore.swift:11965-11994`).

**Workspace switching is a two-page carousel with no cover.** This is the part
Fyolo has not built, and it is the most interesting thing in the repository.
`Views/SidebarWorkspaceDots.swift` (1830 lines) turns a two-finger swipe into an
interactive pager: one fixed-size clipped container holds two materialized pages
of the same list component — the live page driven by the store, the neighbor
driven read-only from a pooled snapshot. Commit slides the container one page
over so the pooled page lands at x=0 already showing its final pixels, then a
single unanimated transaction performs the scope switch and re-bases the
container. The design note is worth restating exactly because it is a general
principle: *identical inputs on both pages by construction — never by
synchronization — is what makes the swap invisible.* Both pages read the same
persisted expansion set, both render from the top, and the scope switch seeds the
runtime with the exact snapshot the pooled page rendered from. The header lists
what that buys: "no peek panel, no freeze, no cover timer, no opacity swap".

Two smaller techniques ride along. The carousel is a `ViewModifier`, so
per-scroll-event updates re-run only the modifier's body while the heavy live
tree arrives as an unchanged `Content` proxy and is never re-diffed per event.
And its `store` reference is deliberately *not* `@ObservedObject`, so pooled page
content is derived once per (row, snapshot) instead of on every store publish.

### zed — state outside the tree makes removal free

`crates/workspace/src/pane.rs`. Activating a tab is three lines of real work:
assign `active_item_index`, notify the previous item that it was deactivated, and
call `cx.notify()` (`activate_item`, line 1474). The pane's render then puts
exactly one child in the element tree — `self.active_item()` — and the inactive
items are not rendered at all (line 4541).

The point is not that this is clever. It is that in GPUI it is *possible*: every
item is an entity whose state lives in the entity, not in the element tree, so
dropping it out of the tree costs nothing and preserves everything. Zed gets
free-removal and free-retention at the same time because its state and its view
are different objects.

SwiftUI does not give you that by default. `@State` and `@StateObject` live in
the view tree, keyed by structural identity; remove the subtree and the state
goes with it. That single difference is why unpeel's answer looks like a manual
cache of AppKit views and zed's answer looks like a one-line index assignment.
The underlying architecture is the same architecture. SwiftUI just makes you
build the entity store yourself.

### codex — the opposite pole, and why it works there

`openai/codex` has no native macOS view layer; its UI is a Rust `ratatui` TUI
under `codex-rs/tui`. It cannot answer the SwiftUI question, and it is included
here because it answers a different one: what happens if you *don't* retain the
view.

Codex holds one `ChatWidget`. Threads are not retained view trees — each thread
has an event channel and a `ThreadEventStore`, and switching means replaying a
snapshot into a replacement widget
(`app/session_lifecycle.rs:757`, `replace_chat_widget_with_app_server_thread`).
What has to survive the rebuild is captured and restored by hand:
`store_active_thread_receiver` calls `capture_thread_input_state` before parking
a thread (`app/thread_routing.rs:73-84`), and restoration is an explicit
`ThreadInputStateRestoreMode`.

Where it does cache, it caches *measurement*, not content: `CachedRenderable`
(`pager_overlay.rs:399-430`) memoizes a renderable's desired height per width,
and the transcript overlay recomputes its live tail only when a revision-based
cache key moves. That is the right instinct in any layout system — the expensive
part of a text-heavy tree is usually measuring it, not drawing it.

Model-side retention with view-side rebuild works for codex because rebuilding a
`ratatui` widget from a snapshot is cheap and total. It does not transfer to a
libghostty pane, where "the view" owns a PTY, a Metal surface, and a scrollback
that no snapshot reconstructs in a frame.

## Part 3 — What Fyolo's architecture should be

**The rule: state that is expensive to rebuild lives outside the SwiftUI tree,
and the SwiftUI subtree is removed when it is not shown.**

Every measurement in Part 1 points at this and nothing else. Removal is the only
thing that skips work. Retention inside the tree is a tax on every future update.
So retain outside, and remove inside.

Three tiers, by what the thing costs to rebuild:

**Tier 1 — things holding a live OS resource.** Terminal surfaces, and anything
else owning a PTY, a Metal layer, or a child process. These are AppKit `NSView`s
held by a cache keyed on session id, attached to and detached from a swap
container by an `NSViewRepresentable`. They are never a SwiftUI subtree, so
SwiftUI's removal of the container costs nothing and destroys nothing. Fyolo
already does this. What the prior art adds is the discipline around it: teardown
deferred off the layout pass and revocable by token, a synchronous focus-and-draw
inside the swap so the first committed frame is correct, and a cap of one new
surface creation per update pass.

**Tier 2 — things expensive to derive but cheap to render.** The realized file
tree, a device roster, per-project session orderings. These live in a plain
non-`@Published` cache keyed by root or scope, and the view rebuilds from the
cached value on demand. `FileTreeCache` (capacity 8, LRU) is already this shape.
The gap is the sidebar's own row lists, which unpeel memoizes and Fyolo derives
per render pass — and the `feat/workspaces` branch multiplies that cost by the
number of workspaces in flight.

**Tier 3 — everything else.** Rebuild it. A few hundred cheap rows cost tens of
milliseconds only when they are all in the tree at once; removed, they cost zero.

On top of the tiers, four rules about the switch itself:

1. **Nothing about a switch animates.** Not the container, not the transition,
   not the scroll that lands with it. `.transition(.identity)` plus
   `.animation(nil, value:)` on the container, and `Transaction.disablesAnimations`
   at the mutation site. The two are not interchangeable: the transaction flag
   travels with the mutation, and a modifier already attached to the subtree is
   what stops a *different* mutation from animating the same tree later.
2. **Paint the cheap half in the current transaction; defer the expensive half
   one runloop turn, guarded by a re-check that the target is still selected.**
   Fyolo ships this and unpeel converged on it independently, which is about as
   strong a signal as prior art gets.
3. **For Metal-backed panes, force a synchronous draw inside the swap.** The
   switch was never the slow part; the stale drawable and the hollow cursor for
   one frame are what read as lag.
4. **Pre-warm on intent, not on hover.** A dwell around 450ms, a cap around 3,
   the just-left session included, one creation per pass, mounted hidden but
   still ticking, and frozen against resize while a live drag is in progress.

And one rule about steady state, because a switch that lands into a stuttering
app is not instant: high-frequency values must not invalidate the heavy tree.
`SessionRuntime` (see `20260724-sidebar-scroll-performance.md`) is the pattern
already; unpeel's carousel-as-`ViewModifier` is the same idea aimed at a gesture
instead of an agent tick — isolate the value that changes often into a small view
that receives the heavy tree as an opaque proxy.

## Part 4 — Rejected

### Keeping the inactive column mounted under `.hidden()` or `.opacity(0)`

The obvious idea, and the measured trap. It buys a 3.1ms switch instead of a
31.5ms one, and charges 36.7ms instead of 19.7ms for every unrelated update
afterwards, scaling linearly with the number of retained columns. For an app
whose whole job is to sit there while several agents write output, that is a bad
trade in the direction Fyolo cares least about. It is also the mechanism that
would produce a mysterious idle CPU floor, so it is worth grepping for before
theorising further.

### `.frame(width: 0, height: 0)` as a cheap hide

Drops `sizeThatFits` calls from 90 to 30 and changes nothing else: 600 body
evaluations, 60 placements. It suppresses the parent's size negotiation, not the
child's work.

### `drawingGroup()` / `compositingGroup()`

Neither skips a single body evaluation (300 of 300 in every configuration), and
`drawingGroup` rasterizes the subtree into an offscreen Metal buffer — which a
subtree hosting its own `CAMetalLayer` cannot survive. Wrong tool twice over.

### Snapshot-and-crossfade, or freezing the view during a switch

Capturing the hosted tree with `cacheDisplay(in:to:)` costs 13.2ms of
main-thread time, before the switch it is meant to hide, which itself costs
31.5ms. It makes the switch 40% more expensive in exchange for hiding the fact
that it is expensive. Worse, a crossfade over a `CAMetalLayer` is precisely the
operation unpeel identified as the cause of its settings blink.

unpeel reached the same conclusion from the other direction and wrote it into
its carousel design: no peek panel, no freeze, no cover timer, no opacity swap.
Their alternative is the one worth copying — make both sides render from
identical inputs so there is nothing to hide.

### Animating the switch at all

This is the thing the profile found. Beyond the flash across a Metal layer, an
animated transition moves the layout work into `NSAnimationContext`'s completion
path, where it is both slower to finish and harder to attribute. A switch is a
change of subject, not a movement of objects; there is nothing for the eye to
track between an old session's scrollback and a new one's.

### Rebuilding the view from a model snapshot on every switch (codex's model)

Correct for a `ratatui` widget, wrong here. A libghostty pane owns a PTY, a
GPU surface, and scrollback. Reconstructing that from a snapshot within a frame
would need a per-frame grid encoder between the PTY and the renderer, which is
the exact thing `20260730-fyolod-session-protocol.md` §A rejects as the tmux
tax. Worth stealing from codex instead: caching *measurement* per width, and
capturing the small pieces of view state that must survive a rebuild
(composer text, scroll position) explicitly rather than hoping identity holds.

### Per-workspace remembered scroll offsets

Relevant to `feat/workspaces`. unpeel considered and rejected them: restoring a
pixel offset needs the macOS 15 `ScrollPosition` API, and id-based `scrollTo`
restoration is approximate under lazy layout, so the two pages of a switch would
not agree. Their replacement is to make *every* page land at the top, so both
sides of a switch agree by construction. Fyolo should adopt the same default —
top-landing, unanimated, in the same commit as the scope change — before
considering offset restoration.

### Debouncing the post-swap resize

unpeel tried a trailing 80ms debounce of `fitToSize` on layout and left a note
saying it never worked: `super.layout()` applies the edge constraints, which
drives the resize synchronously in the same pass, so the debounced call only ever
fired as a same-size no-op later (`GhosttyBridge.swift:590-596`). Their fix was
to make the source cheaper — synchronous render, no-stretch gravity, hidden panes
frozen during a live resize. A same-size `fitToSize` is also a no-op to ghostty,
which is why a switch needs an explicit force-refit rather than a plain fit.

### Pausing hidden pre-warmed surfaces

Intuitive and dangerous. `setSurfaceVisible(false)` suspends the wrapper's
wakeup→tick→draw loop; a surface that never ticks while its client floods the
replay wedges its IO, and the next synchronous surface call from the main thread
deadlocks. Pausing is correct for a *detached* pane (`window == nil`) and for an
occluded window, and wrong for a mounted-but-hidden one.

### Tearing a surface down synchronously when the cache evicts it

`prune` runs inside the publish/layout path. Freeing a Ghostty surface there
froze unpeel's app. The eviction has to move to a later main-loop turn, be
staggered so several evictions do not land in one frame, and be revocable —
otherwise a pane reclaimed during its stagger window gets a second client spawned
underneath it.

## Open questions

- The 3–22% idle CPU with one working session is unexplained. Part 1 gives one
  mechanism that produces exactly that signature, and
  `20260724-sidebar-scroll-performance.md` gives a second (object-level
  `ObservableObject` invalidation). Both are worth ruling out before looking for
  a third.
- Whether `Transaction.disablesAnimations` at the mutation site actually reaches
  the `NSAnimationContext.runAnimationGroup` frame seen under
  `NSHostingView.layout()`. The two live on different sides of the hosting
  boundary, and the profile does not say which one opened the group.
- unpeel's public repository is gone. The reading above is from a local clone at
  `d017f75`; anything checked later has to be checked against that clone, not
  against GitHub.
