---
title: Input during a pending host resize
status: archived
type: bug
created: 2026-09-13
updated: 2026-09-13
---

# Input during a pending host resize

> Historical investigation for [issue #633](https://github.com/fl0wo/fyolo/issues/633).
> The affected Swift PTY implementation was removed before this patch reached
> `main`, and the current `fyolod` backend prevents the timing defect by
> construction (see "Resolution against main"). The reported visual symptom was
> never reproduced, so its absence on the current backend cannot be proven, only
> its known cause ruled out.

Reported September 13, 2026: Claude input and its cursor sometimes appear above
the prompt line after switching away and back. The exact visual symptom has
not yet been reproduced locally; the report does not establish whether the
switch was between apps or between fyolo sessions.

Investigation found a concrete timing defect: `resizeFromHost` records the
surface's new grid immediately but coalesces the PTY update for 50 ms.
`claimHostOwnership`, called before surface input is written, previously
returned early when the host already owned the size. That allowed input to
reach the child while its kernel terminal size still described the old grid.

The patch at `d9ac2430` cancels the deferred work and applies the latest host grid
before returning, regardless of previous ownership. Unchanged sizes remain
no-ops. Background host layout changes still respect companion ownership.
This closes that input timing gap; it does not establish that all Claude
cursor-placement glitches are fixed or force a child to finish repainting
before it handles input.

## Historical verification

At `d9ac2430`, `tools/tests/pty-host-resize.swift` launches a real PTY child and asks `stty
size` for its kernel grid before the main runloop can deliver the coalesced
resize. Before the fix it reports `24 80` instead of `40 120`; after the fix it
reports `40 120`. The same test checks companion ownership during a background
host resize and restoration of the host grid on host input.

The test and fix remain available at that commit. The test was removed from the
merged tree because it depends on the deleted `PTYProcess` class.

## Resolution against main

`main` owns PTYs in `fyolod/src/pty.rs`, and the resize-before-input ordering the
old patch had to restore now holds by construction. Input and viewport frames
travel one connection in order (`FyolodClient.send`, `FyolodClient.swift`), and
the daemon handles `Input` and `Viewport` in a single actor loop, so a frame is
resolved before the one behind it (`session.rs`, `SessionMsg::Input` /
`SessionMsg::Viewport`). The `Input` arm calls `apply_size_policy` immediately
before forwarding the bytes, and `apply_size_policy` applies `TIOCSWINSZ`
synchronously in-line (`session.rs` → `pty.rs` `set_winsize`) — no deferred
callback. So the kernel PTY is always at the current grid before input reaches
the child, which is the exact opposite of the 50 ms coalescing window that made
the old defect possible. There is no equivalent path on the current backend.

The merge keeps that implementation and removes the obsolete Swift class and
its standalone test. There is no production-code change relative to `main`.

The known mechanism is therefore ruled out on the current backend. What is not
proven is the reported visual symptom itself: it was intermittent and never
reproduced, so this records the elimination of its only identified cause, not a
reproduction. Reopen #633 only if the misalignment recurs on a current build.
