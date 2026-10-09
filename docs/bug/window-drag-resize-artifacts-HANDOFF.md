---
title: "Resize mojibake: one symptom, eleven causes"
status: done
type: bug
created: 2026-09-01
updated: 2026-09-04
related:
  - ../design/20260901-pty-size-is-not-the-write-token.md
  - ../design/20260730-fyolod-session-protocol.md
  - terminal-resize-no-reflow-HANDOFF.md
  - phone-attached-resize-HANDOFF.md
  - agent-tui-focus-report-resize-storm.md
---

# Resize mojibake — one symptom, eleven causes

> Closed. Everything below shipped in **v0.49.0** (PRs #591, #599, #603, #606).
> This is the consolidated record of a three-day investigation that produced
> fourteen commits, five wrong answers, and one lesson worth more than the fix.

## 0. The reports, in order

Every line here is the reporter's, dated. The order matters: each one was
produced by a *different* cause, and treating them as one recurring bug is what
cost the first two days.

| when | words | cause |
| --- | --- | --- |
| 09-01 | "right sidebar 展开折叠 无法 resize tui" | §3.1 |
| 09-01 | "resize 过程抖动 and 依然错位" | §3.2, §3.3 |
| 09-01 | "drag 过程中还是会乱？结束的时候不乱" | §3.4 |
| 09-01 | "完全不会 resize 了" | §4.1 — a regression chasing the above |
| 09-02 | "why 拖动屏幕 tui 乱码" + screenshot | §3.6, §3.7 |
| 09-02 | "往内拖拽没有问题 往外拖拽还是有问题" | §3.8 |
| 09-04 | "怎么还是有问题啊？我印象里昨天晚上一个 dev 的版本是可以的" | §4.4 — not a bug at all |

## 1. The short answer

One PTY, **two terminal emulators**. libghostty runs a full VT on the client and
reflows on its own authority; fyolod runs a second authoritative VT as a
snapshot sidecar. Every artifact in this file lives in the gap between them —
what one reflowed, when the other was told, and which of the two the user was
looking at while they disagreed.

Nothing here is exotic. Each cause is a place where the *order* of three events
was wrong: the PTY resize, the child's answer to it, and the screen a viewer was
handed.

## 2. Why one symptom had eleven causes

A resize is a **barrier**, not an ioctl. In a plain terminal, resizing is one
`TIOCSWINSZ` on a PTY the emulator owns alone; the child repaints and the whole
thing is over in a frame. Here it is: derive the new size from every
attachment's viewport, resize the PTY, reflow the sidecar VT, quiesce, capture a
snapshot, fan it out to every attachment, then let buffered output through.

That barrier has an order the client cannot see and cannot influence. On the
wire it is always:

```
S (a screen at the new grid) -> E ready -> buffered data -> E resized (the new grid)
```

**The client learns the new size after the keyframe describing it.** No
client-side ordering can win that race, which is why four separate attempts to
fix it client-side (§4.1) failed before anyone read `apply_size_policy` and
found `begin_snapshot_barrier()` sitting above `emit_event`.

## 3. The causes

### 3.1 The session was sized to the smallest viewer

`size = min(viewport of attachments rendering)`. Any second viewer — another
window on the same daemon, a phone with the session open — held every other one
at its width, so collapsing a pane's sidebar moved nothing.

Measured before: one window, ⌘⌥0 moves the PTY 41×63 ↔ 41×97 every time; a
second window at 700×600 pins it at 41×61 and four toggles move nothing.

**Fix** (`bdbe866b`, #591): `size = viewport of the most recently *used*
attachment`, where a use is typing, declaring a changed viewport, or attaching —
never output, never a device report, never a token claim. tmux's `latest` with
zellij's rendering filter.

### 3.2 The screen was truncated instead of rewrapped

fyolod's VT resized without reflow on purpose: a shell answers SIGWINCH by
moving the cursor up a row count computed from the **old** width, so rewrapping
under it duplicates the prompt (the ⌘D report). But every attachment repaints
from that screen, so a line the program had wrapped stayed broken where it was
broken: widen the window and rows start mid-word. `mage in clipboard` in the
reporter's screenshot is `image in clipboard` with the `i` still on the row
above.

**Fix** (`d41ea790` → `81210326`, #591): gate on what is on screen — a shell
gets the truncating resize, anything else gets the rewrap.

**The first version of that gate shipped wrong.** It asked `foreground.job`, but
an agent session is `zsh -ilc exec claude`: `exec` replaces the shell image, the
child *is* the agent, its pgid is the session's own, and the answer was always
"no job". Every agent session kept the truncating resize — the sessions that
needed rewrapping most. It now matches argv0 against a closed set of shell
names. Pinned in `vt/tests/resize_reflow.rs`.

### 3.3 A barrier per intermediate size

A viewport flushed on a fixed cadence made a drag ~20 barriers a second, each
one quiescing the session and pushing a fresh keyframe to every attachment,
racing the child's own redraw. Ghostty affords 25 ms because its resize is an
ioctl; ours is a barrier. tmux rate-limits a pane to one resize per 250 ms,
zellij collapses a burst to its last, cmux debounces 180 ms — none of them are
wrong about it.

**Fix** (`6fef00b3`, #591): one send per drag, at the end. Measured on a real
2.8 s drag: six declarations, each answered by the daemon in 2–11 ms.

### 3.4 The keyframe was painted onto a surface at the old grid

The wire order in §2 means the keyframe arrives before the client knows what
size to become, so it was painted through the old grid — one mangled full-screen
frame — and repaired by a second keyframe a round trip later. Two full repaints
per resize, and a slow drag crosses several cell boundaries.

**Fix** (`2d5d726d`, #599): `TerminalKeyframeHold` holds a keyframe whose grid
the surface is not laid out at, queues the bytes that arrive behind it, and
emits both — in order — the moment libghostty reports that grid. One paint per
resize, and it is the right one.

### 3.5 A resync a client asked for was never answered

Found while measuring §3.4. `SessionMsg::ResendSnapshot` asked the sidecar for a
capture but never opened the attachment's snapshot barrier, and
`finish_snapshot` matches every capture against the request the attachment is
waiting on. With no barrier open that is `None`, so **every client-requested
resync was captured and then discarded as stale**. The client asked for a
repaint, the daemon produced one, and nobody ever saw it. Broken for as long as
the verb had existed.

**Fix** (`f7e42e38`, #599); pinned by
`session::tests::a_resync_a_client_asked_for_reaches_it`.

### 3.6 The keyframe described a screen the child had already replaced

`apply_size_policy` resized the PTY, told the sidecar to reflow, and asked for
the snapshot in the same handler — deliberately, and the comment said so: *"these
requests are adjacent to the Resize command in the sidecar FIFO, with no
intervening Write command."* Adjacent to the resize means **before** the child's
answer to it. Every resize therefore shipped every attachment a full-screen
paint of a screen that was already wrong.

**Fix** (`dc3ac66a`, #603): the barrier still opens with the resize, so nothing
reaches a client ahead of the grid that describes it; the capture waits for the
child. Its first byte pulls the deadline in to 5 ms; 40 ms is the cap for a
child that never answers.

Waiting on a **clock** instead is not free, and a test says so: `E resized` is
deferred behind the open barrier, so a flat settle delays every viewer's notion
of the session's size, and `testTheSessionIsTheScreenBeingUsed` fails on a flat
40 ms one. Any future change here must keep that test honest rather than widen
its tolerance.

### 3.7 A given-up keyframe was painted anyway

The hold has a 250 ms deadline and a 1 MiB flood cap so it stays a hold and not
a stall. **Both endings painted the keyframe** — a screen drawn for one grid
written into a surface laid out at another, which wraps every row somewhere the
daemon never put it. A guaranteed scrambled frame, then the surface's own reflow
of it, then the resync that replaced it a round trip later. A drag is exactly
the condition for missing that deadline: the deadline is a main-thread layout
pass, and a drag is a busy main thread.

**Fix** (`39c1cff2`, #603): both endings drop the keyframe and arm the repaint,
leaving the last correct screen up. Teardown still paints — a surface going away
has no repair coming, so an imperfectly wrapped final frame beats a blank one. A
500 ms backstop covers a surface that never reports the exact grid, and a
keyframe answering a repaint we asked for is not re-held, which would loop.

### 3.8 The surface was pinned for the whole drag

Dragging **outward** left the terminal in the top-left corner of a pane growing
around it, with a widening band of background beside it, until the declaration
was answered and it snapped out. Dragging **inward** looked clean, because the
same pin makes the surface larger than the pane and it is clipped — the content
still reaches every edge. That asymmetry is why the report was
"往内没问题、往外有问题".

The pin exists so a surface never re-wraps a screen at a width nothing was drawn
for. That is the *shrinking* direction. Growing only rejoins rows.

**Fix** (`39c1cff2`, #603): a viewport that **contains** the authoritative grid
may lead it — growth on both axes, never shrinkage — until the daemon adopts the
viewport, the direction stops being growth, or 600 ms passes. The lead is raised
only by this pane's own geometry changing, so a phone that takes the size can
never unletterbox this window. Pinned in `TerminalViewportGridTests`.

This re-introduces the `viewportPending` window §3.4's fix had deleted,
restricted to the one direction the objection does not apply to. Read it as an
evolution, not a revert.

### 3.9 A hidden pane keeps the grid it left with

The main cause of the last round. A pane outside the layout still has a live
link feeding it bytes, and its surface keeps whatever grid it had when it
stopped being laid out. Every byte drawn for the session's later widths wraps at
that stale one, and the wrap points are **baked into the surface** — re-layout
cannot undo them, it only re-wraps the lie at the new width. `repaintPending`
never fires either: it is armed by surface reports a hidden pane does not
deliver.

**Fix** (`b072a85f`, #606): coming back on screen is a boundary and takes a
snapshot, the way attach does. It goes *through* the hold, not around it —
§3.7's `requestResyncLocked` force-paints its answer, which is right for a hold
that already failed and wrong for a pane about to be laid out, where it would
draw the session's screen through the very grid the boundary exists to discard.
Hence the `paintImmediately` flag.

### 3.10 The coalescer declared sizes nobody chose

A pane's width also moves when the **app** animates layout — opening a session,
toggling the sidebar — and those animations pause long enough mid-flight that
the 150 ms timer fired on an animation frame. A traced session open declared
**68 columns on its way from 97 to 97**. The child's repaint for that width then
races the next resize, and bytes drawn for it parsed into the final grid are the
glued, miswrapped rows reported after every session open.

**Fix** (`b072a85f`, #606): 400 ms. This is mitigation. The real answer is
declaring only at boundaries, and it is still not done (§6).

### 3.11 Nothing made the child repaint after the dust settled

Bytes drawn for the old grid can still be in flight through the PTY when the VT
takes the new one — nothing orders a child's output against a resize it has not
seen yet — and whatever they painted, only the child's own repaint can
overwrite.

**Fix** (`73e45667`, #606): 300 ms after the last resize the foreground gets one
more SIGWINCH, re-armed by every resize so a drag costs one nudge at the end.
Shells are excluded for §3.2's reason. A ring replay the daemon knows is
unfaithful gets the same nudge — that is the frozen, mangled screen after a
handoff, where an idle agent produces no next output and a viewer already at the
session's size gets no resize either.

## 4. What was wrong that was not a cause

The most expensive part of this investigation. Four of these cost more than any
real fix.

### 4.1 Four client-side orderings, all doomed

"Let the surface lead its own declaration", "hold the surface still until the
resize is on the wire", "stop letterboxing a pane against its own resize",
"anchor instead of centre" — four commits over one afternoon, each a guess about
ordering, made by agents that could not see the screen. §2 is why none could
work: the pane cannot know the grid before the frame that carries it. One of
them also regated the letterbox from `!isWriter` to a grid comparison, which is
correct under a size policy and catastrophic without one — an older daemon reads
a resize as *set the PTY size, from the writer*, so the pane stayed pinned
forever: *"完全不会 resize 了"*. The pane now asks the handshake for the
`viewport` capability before it letterboxes at all (`c1686aa7`).

### 4.2 The 45↔46 row oscillation was not points-vs-pixels

Suspected for a day to be `TerminalGrid.fitting` disagreeing with libghostty's
pixel floor. It was not. The trace was extended to carry the inputs behind each
declaration, and they named the cause outright: `installToolbar()` ran **after**
`makeKeyAndOrderFront`, so every launch measured a content rect one row too
tall, declared it, and had the daemon answer — resizing the PTY and pushing a
keyframe for a grid that lived 40 ms. Fixed by installing the toolbar before the
window is shown (`15ed89b7`). Launch now sends zero redundant declarations where
it used to send two.

### 4.3 The phone-attached report was a leaked environment variable

A whole sibling investigation (`phone-attached-resize-HANDOFF.md`) measured a
pane at the wrong grid on a branch that could not produce it. The dev app had
been launched from a shell inside Fyolo, which exports `FYOLOD_SOCK`; that
overrides `FYOLO_CHANNEL`, `open` passes it to the app, and the dev build
attached to the **release** daemon — v0.48.0, no size policy, where PTY size
*is* the write token. Launch with `env -u FYOLOD_SOCK`.

### 4.4 "It broke again" was a build that never had the fix

09-04. Reported on a build that already carried §3.6–§3.8. It did not: the dev
app had been built that morning from a checkout whose `main` sat **six commits
behind** `origin/main`, at the commit before those merged. Grepped against the
source it was built from — no `growingViewportPending`, no `abandon`, no
`RESIZE_SNAPSHOT_SETTLE`. Nothing had regressed; the machine had never run the
fix.

The same checkout also held a day of **uncommitted** work from a parallel
session — §3.9–§3.11, diagnosed and fixed but never branched. Two fix sets
existed, neither build had both, and both touched `FyolodClient.swift` and
`session.rs`.

**Check what the running binary was built from before believing a symptom.**
`fyolod status` names the daemon; the app's build time against `git log` names
the app. And note that **the daemon does not restart when the app is rebuilt** —
`fyolod handoff` replaces it in place, keeping every PTY.

## 5. The measurements that settled it

Nothing in §3 was argued. Each of these ended a debate.

**What the child does with a SIGWINCH.** Captured from a real PTY: Claude Code
answers `ESC[?25l ESC[2J ESC[H` plus a full absolute redraw — it clears the
whole screen and repaints from its own model. Latency from the ioctl to the
first byte, four trials: **0.1–0.3 ms**. zsh's redisplay, same harness:
**7–23 ms**. This is what justifies §3.2's gate and what makes §3.6's wait
cheap.

**The screenshot, decoded to the column.** At 82 columns Claude Code writes its
hint row then `ESC[66G` — `/rc` at column 66. Rewrap that screen to 66 and `/`
is the last cell while `rc` wraps; the 78-cell border splits into 66 + 12. That
is the reporter's picture, glyph for glyph. Reproduced directly against
`fyolod-vt`: 82 → 55 gives a 55-cell run, a 27-cell run, and `for age` / `nts /
rc`. The `/rc` "sticking" was never sticking — it is Claude Code's
right-aligned `/rc` falling off a wrap.

**A real drag.** Six declarations in 2.8 s, each answered in 2–11 ms.

## 6. Still open

- **Boundary-only viewport declaration.** §3.10's 400 ms is a mitigation. A pane
  should declare when its geometry *settles*, not when a timer fires during an
  animation.
- **A true assigned-grid pin.** cmux pins the surface's pixels to the
  authoritative grid regardless of view or visibility — hidden panes included —
  checks grid parity both ways, and kicks a repaint after a grow. Ours needs
  `InMemoryTerminalSession.updateViewport` made public in the fork.
- **The mirror-mode RFC.** cmux does not have this family because it never runs
  two terminal authorities: a remote pane is `manualMirror`, where the embedder
  owns the PTY and the terminal protocol and Ghostty only renders. fyolo's
  `.inMemory` is cmux's `manual`. A mirror mode would delete this class by
  construction, and must be argued against §A's anti-100× invariant.
- **Sidecar never recovers after a handoff.** `mark_vt_stale` is a permanent
  downgrade; §3.11's nudge fixes the frozen screen but ring-replay residue stays
  in scrollback.
- **iOS paints keyframes immediately** — it has no equivalent of the hold.
- **#602** (a surface with no screen taking the session's size) is still open and
  touches the same three files.

## 7. Tooling, for the next one

- **The trace.** `resize-trace` lines are at `.info` — `log stream --level info`
  catches them, `log show` does not persist info, and `log config --mode
  level:debug` needs root. A release-config dev build is the only one that emits
  them usefully.
  ```
  declare 45x97  -> what this pane told the daemon
  session-is 45x97 -> what the daemon answered
  surface-at 45x97 -> what libghostty laid the surface out at
  measure pane=... cell=... scale=... grid=... -> the inputs behind a declaration
  resync-requested / keyframe-held-out / keyframe-flooded-out -> the degraded paths
  ```
  Four links log into one stream — one per open session plus the companion
  bridge — so the session name on every line is not decoration.
- `FYOLO_TERMINAL_DEBUG=1` with `launchctl setenv` exposes ghostty's inner
  metrics.
- **Screenshots of the app** must go through the `fyolo.dev.snapshot`
  distributed notification sent with `swift -e` (JXA cannot send it); Metal
  content is invisible to `screencapture`, which also needs a Screen Recording
  grant nobody driving this ever had.
- **The daemon's own truth**: render `fyolod attach --observe` through pyte, or
  read a snapshot's `vt` payload directly. An observer declares no viewport, so
  it never moves the session's size.
- Never launch a second dev app from another path — it revokes the running one's
  `~/Documents` TCC grant.
