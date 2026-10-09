---
title: "Resize stubs: five fixes, and the witness that lied"
status: done
type: bug
created: 2026-09-15
updated: 2026-09-15
related:
  - window-drag-resize-artifacts-HANDOFF.md
  - terminal-resize-no-reflow-HANDOFF.md
  - ../design/20260901-pty-size-is-not-the-write-token.md
  - ../design/20260730-fyolod-session-protocol.md
---

# Resize stubs — five fixes, and the witness that lied

> Confirmed on device and fixed. The artifact was a keyframe parsed at a grid
> the client's VT had not reached yet. Five other real defects were found and
> fixed on the way; none of them was this one. §4 is the cause, §6 is the fix
> that landed, §5 is the proof still owed.

## 0. The report

> "when you move left right sidebar the fyolo winsize will resize right but
> why click max/min traffic light it didn't work"
> "往外拖动的时候依然" — with a screenshot, after each of five fixes

Widening the terminal — by the green button, by a window edge, by a split
divider — leaves fragments of the previous render on screen. Narrowing never
does. The final, most diagnostic screenshot shows **full-width rules with
single-cell `─` stubs at column 1** on the rows between them.

That asymmetry and that shape are the two facts the whole investigation turns
on, and both were on screen from early on.

## 1. What is fixed, with the evidence for each

Every one of these is a genuine defect on the resize path. **None of them is
the artifact.** They are listed so the next person does not re-find them.

| commit | defect | proof |
| --- | --- | --- |
| `14e395bf` | a split-divider drag never streamed its size: the cadence gate only knew about `NSWindow` live-resize, so a divider drag took the 400ms animation debounce and the session reflowed *after* release | **verified on device** — trace shows declares ~155ms apart during the gesture |
| `eac323a8` | — | pins the gate's begin/end pairing contract |
| `145f8e2f` | the daemon replayed the child's redraw **twice**: a resize opens its client barrier at once and captures up to 40ms later, so the answer to SIGWINCH was both parsed into the snapshot *and* buffered for replay on top of it | test fails before / passes after |
| `fbd653d9` | the client's keyframe hold gave up after 250ms and flushed the increments queued behind the dropped keyframe — cursor-addressed updates against a base the surface never received | contract pinned by tests |
| `71a6c3ba` | only *growth* was allowed to lead the daemon, so a widening surface parsed bytes at a width the daemon had not reached. Deleting it gives fyolo ghostty's invariant: one authoritative width, no parser anywhere else | net −81 lines |
| `071e5249` | the resize capture was pinned to the child's **first** answering byte + 5ms. Beginning a repaint is not finishing one; it now quiesces (12ms, re-armed per byte) under a 150ms cap | test fails before / passes after |
| `d06c0a3a` → `102fc81f` | reflow clipping for cursor-addressed regions — **reverted**, see §3 | — |

## 2. What was ruled out, and how

**The traffic light is not a fyolo bug.** Three independent witnesses — a
CGWindow frame poll, the app's `resize-trace`, and libghostty's own surface
callback — agree the window frame does not move when the button is clicked on a
window already at the macOS fill frame. `EnableTiledWindowMargins = 0` puts the
fill frame at exactly the visible frame, and a window already there has nothing
to toggle to.

**Reflow does not damage the canvas on its own.** `vt/tests/resize_tui_canvas.rs`
walks a TUI box through a coarse resize *and* through a real drag's
one-column-at-a-time narrowing and widening. Both come back whole. Reflow only
strands rows when the child redraws **while narrow** — a different experiment,
and the one the `#[ignore]`d reproduction pins.

**The daemon's screen is clean.** Every session's current screen was read
through `fyolo-dev sessions read` while the artifact was displayed. No stub
anywhere. Whatever is on screen is not in the daemon's VT.

## 3. The reverted spike, and why

`d06c0a3a` keyed the resize policy on terminal state instead of the foreground
process name, clipping overwide cells in cursor-addressed primary-screen
regions before reflow. It passed 397 tests including the reproduction.

It was reverted anyway. Detecting "cursor-addressed" cost a second
escape-sequence parser inside `fyolod/vt`, the crate whose job is to be a thin
wrapper over ghostty's VT, and inferring an erasable region from cursor movement
is not proof of canvas ownership — the clipping can erase content that is not
the app's to lose. It also fixed a shape real drags do not produce (§2).

**The policy question it raises is still open and still real.**
`foreground_is_a_shell` protects prompt redisplay for shells and leaves every
full-screen TUI to be rewrapped, on the stated reasoning that only a shell does
width-relative arithmetic. That reasoning is wrong: repainting from your own
model *is* width-relative arithmetic the moment you walk the cursor back over
rows you drew, and every full-screen TUI does exactly that.

## 4. Where the evidence points now

**`surface-at` measures the wrong thing, and it is the witness the whole
investigation trusted.**

`TerminalSurfaceCoordinator.swift:236` calls `setSize` and then immediately
reports `surface.size()`. That returns **surface geometry**, not the parser's
dimensions: `ghostty_surface_size` reads `core_surface.size.grid()`, not
`io.terminal.rows/cols` (`embedded.zig:1961` at ghostty `8867c37`). Setting
geometry only *queues* an IO-thread resize, and ghostty coalesces those for
**25ms** (`Thread.zig:390`) — while keyframe bytes reach `processOutput` through
our own host-managed-IO patch, **bypassing that queue**.

So the client can release a held keyframe because the grid "matches", parse a
screen formatted for N columns **at N−1**, mark it painted, clear
`repaintPending`, and never resync.

A keyframe parsed one column narrow wraps every full-width row by exactly one
cell. **That is the single-cell stub**, and it is the only mechanism proposed
that predicts the observed shape. It also explains why the trace looked healthy
through five fixes: matching grids, no held-out keyframe, no resync.

Related: the timeout repair currently lets the next snapshot through regardless
of grid (`FyolodClient.swift:1195`), so arming a resync is not proof of repair.

## 5. The measurement nobody can take yet

The question is one line: **is the Mac VT's parser at the grid the keyframe was
formatted for?**

No accessor exposes that. Not in libghostty-swift 1.0.24, not in its C header,
not in either fork patch. The surface handle is opaque; the text and inspector
APIs do not reach it. The host-managed resize callback cannot stand in either —
it fires inside `backend.resize`, *before* `terminal.resize` (`Fyolo.zig:493`).

The smallest change that would answer it: a diagnostic variant of
`ghostty_surface_write_buffer` (`Patches/ghostty/0002-host-managed-io.patch:244`)
returning the terminal's rows and columns sampled immediately before parsing,
**inside the existing `processOutput` lock** (`Fyolo.zig:663`). A separate
getter followed by a write introduces a second race and answers nothing.

Cost: a C/Zig addition to the fork, a rebuilt XCFramework, a `Package.swift`
bump, and Swift wiring to emit the comparison for keyframes only.

Confirming line: `resize-trace <session> keyframe=47x74 parser=47x73`.
A matching `47x74` refutes the mismatch — for that application only.

## 6. The fix that landed

Holding the keyframe release until past ghostty's coalescing window **makes the
artifact disappear on device** — confirmed by the reporter against a dev build.
A few lines in `FyolodClient`, no fork, fully reversible.

That is strong evidence, not proof: a 30ms delay could mask a different defect
with similar timing. §5 is still the measurement that would settle it.

Two things it leaves owed. The constant is a timing stand-in for an ordering
guarantee — 30ms is chosen against ghostty's 25ms window and nothing enforces
the relationship; the guarantee belongs in libghostty's host-managed interface,
applying the intended grid and the keyframe as one ordered operation. And the
delay currently covers all of `noteSurfaceGrid`, so the surface-grid bookkeeping
and its trace line are deferred with it; narrowing it to the release path alone
needs its own device check.

## 7. The lesson, which is the same one as last time

`window-drag-resize-artifacts-HANDOFF.md` closed with "one symptom, eleven
causes" and five wrong answers. This is the sequel, and the mistake repeated in
a new costume: **five real defects were found and fixed while the reported
symptom went untouched**, because the instrument everyone read — `surface-at` —
was measuring geometry and reporting it as a parse width.

A fix that passes its test proves the defect it names was real. It does not
prove it was *the* defect. Ask what the witness actually measures before
trusting a clean trace over a user's screenshot.
