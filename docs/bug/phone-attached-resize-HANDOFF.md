---
title: "HANDOFF: a pane renders at the wrong grid while a phone is attached"
status: done
type: bug
created: 2026-09-02
updated: 2026-09-02
related:
  - window-drag-resize-artifacts-HANDOFF.md
  - ../design/20260901-pty-size-is-not-the-write-token.md
  - ../design/20260730-fyolod-session-protocol.md
---

# HANDOFF — a pane renders at the wrong grid while a phone is attached

> **CLOSED.** The mechanism is measured and the causes are fixed. The reported
> pane was never on this branch: the dev app was bound to the **release** daemon
> through a leaked `FYOLOD_SOCK`, and that daemon (v0.48.0, build 1713) has no
> size policy at all — PTY size *is* the write token there, so the phone dragged
> the grid and the Mac's resize was refused. §2 below was measured against a
> daemon nobody was attached to and is **not a finding**. See §8.

## 0. The report

Reporter, on `feat/size-follows-the-device-in-use` with the dev app and an
iPhone paired to it: *"使用 ios 时候 macos 会争夺 size?屏幕抖动,怎么还是有这样的
问题?"* — and, after pairing the phone to the **dev** Mac specifically, *"still
same problem"*.

Their screenshot of the dev Mac shows a Claude Code session in the
`/tmp/DEV-MAC-TEST` project whose composer box is drawn narrower than the pane
that holds it, with the banner and box left-inset rather than filling the width.
A phone screenshot of a `~/.fyolo/chats` Claude Code session shows the composer
box torn open and `Image in clipboard · ctrl+v to pas…` broken across rows —
the §3 artifact family from the sibling handoff (content wrapped for width A,
shown at width B).

## 1. Environment when the evidence below was taken

- Mac app: dev channel, built from this branch. Bundle
  `sh.fyolo.app.dev`, state `~/.fyolo-dev`, companion port 8788, daemon socket
  `$TMPDIR/fyolod-501-dev`.
- iPhone: `FyoloMobile` Debug, installed 2026-09-02, reaching the Mac through
  `tunelo port 8788`. **6 established sockets** to 8788 at the time of measuring.
- A separate release `fyolo.app` (build **0.48.0+1713**) is running on the same
  machine on port 8787. It predates the size policy (build 1826) and the
  focus-report fix (build 1796) by ~120 commits, so **nothing observed against
  the release app is evidence about this branch.** The first two rounds of this
  investigation were wasted on exactly that confusion — both Macs are the same
  hostname and both have a `~/.fyolo/chats` Claude Code session.

## 2. ~~Measured, and unexplained: attachments report nobody attached~~ — NOT A FINDING

Every session on the dev daemon, while the Mac app is visibly rendering several
of them **and** a phone is connected:

```
9b7f8681  45x68  clients=0 attached=0 writer=None  '✳ Claude Code'   ~/GitHub/hispeaking
130736ea  45x21  clients=0 attached=0 writer=None                    ~/GitHub/hispeaking
994bb289  45x46  clients=0 attached=0 writer=None  '✳ Claude Code'   ~/Documents/GitHub/fyolo
95518409  45x65  clients=0 attached=0 writer=None  '✳ Claude Code'   ~/.fyolo/chats
1966684a  45x86  clients=0 attached=0 writer=None  '✳ Claude Code'   ~/.fyolo/chats
e1d0c2c3  24x80  clients=0 attached=0 writer=None                    /tmp/DEV-MAC-TEST
```

**Both of these are artifacts of reading the wrong daemon.** `FYOLO_CHANNEL=dev
fyolod list` reached the `-dev` daemon, which no app was attached to — hence
`clients=0` everywhere, and hence the screenshot's session missing from the
roster: it was on the *release* daemon, where the app actually was. Kept only so
nobody re-derives it. The original text follows:

1. **`attached=0` on a session a pane is showing.** The same query against the
   release daemon returns `clients=1` for open panes and `clients=2` for the one
   the phone also has open, so the field does normally count them. If the Mac's
   panes are genuinely not attached, then no viewport is being declared for them
   at all, `apply_size_policy` has nobody to size by, and every session keeps
   whatever grid it last had — which would explain content laid out for a grid
   the pane is not.
2. **The session in the screenshot is not in the roster.** The sidebar shows
   `DEV-MAC-TEST ▸ Claude Code` selected and running; the daemon knows only
   `e1d0c2c3`, a *Terminal*, at 24x80. So either the app is rendering a session
   the daemon does not have, or the CLI and the app are talking to different
   daemons.

**Confounder that must be ruled out first.** Three `fyolod serve` processes from
the dev bundle are alive, started 17:36, 20:00 and 21:03 on 2026-09-01 — the last
matching a `FYOLO_CHANNEL=dragprobe` app launched during the sibling
investigation. `lsof` did not resolve which socket each holds. If the CLI used
for the table above (`FYOLO_CHANNEL=dev fyolod list`) reached a different
daemon than the app, **the whole table is about the wrong process** and §2 is not
a finding at all. Settle this before anything else:

```sh
# which pid is actually bound to the dev channel's socket
lsof -U | grep fyolod-501-dev
# and what each dev-bundle daemon was launched with
for p in $(pgrep -f "fyolo-dev.app/Contents/Resources/fyolod"); do
  ps eww -p $p | tr ' ' '\n' | grep -E '^FYOLOD_SOCK=|^FYOLO_CHANNEL='
done
```

Killing the strays and relaunching one dev app is the cheap way to get a clean
reading.

## 3. Measured on the release app, for contrast

The session the phone had open there moved **12x27 → 19x39** over a few minutes
with `clients=2`. That is the pre-policy size fight, on a build that has neither
fix, and it is what the reporter first described as 抖动. It is *expected* there
and says nothing about this branch — recorded only so nobody re-measures it and
draws the wrong conclusion.

## 4. How to reproduce

1. Build and run the dev app from this branch
   (`FYOLO_CHANNEL=dev ./scripts/build-app.sh`, then `open ./fyolo-dev.app`).
   Make sure **no other dev-channel app is running** — they share a bundle id, a
   state dir and a daemon, and System Events cannot tell them apart.
2. Turn the companion tunnel on in Settings ▸ Companion (dev ships with
   `companion.tunnelProvider = off`, so a phone off the LAN cannot reach it).
3. Pair the phone by scanning the dev app's QR, and **open a session that only
   exists on the dev Mac** — the release app has same-named projects and the two
   are indistinguishable on the phone.
4. Open an agent TUI (Claude Code) on both ends and watch the pane.

Evidence to collect while it happens:

```sh
# the client's own trace: declare → session-is → surface-at, per session
log stream --predicate 'subsystem == "sh.fyolo.app.dev"' --debug --style compact \
  | grep resize-trace

# what the daemon believes, and who it thinks is attached
env -u FYOLOD_SOCK FYOLO_CHANNEL=dev fyolod list --json

# what the kernel holds — the child reflows from this, not from us
python3 -c 'import os,fcntl,termios,struct
fd=os.open("/dev/ttysNNN", os.O_RDONLY|os.O_NOCTTY|os.O_NONBLOCK)
print(struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0"*8))[:2])'
```

**`FYOLOD_SOCK` leaks.** Any shell inside Fyolo carries it, it overrides
`FYOLO_CHANNEL`, and `open` passes it to the app — so a dev build launched from
a Fyolo terminal attaches to the *release* daemon. Always `env -u FYOLOD_SOCK`.

## 5. Already fixed — do not redo any of this

The sibling handoff `window-drag-resize-artifacts-HANDOFF.md` covers a
*different* bug (the screen during a window-edge drag) and its §5/§10 are done on
this branch. Four things in particular are settled, with tests that fail without
them:

- **The barrier's keyframe is held** until libghostty reports the grid it
  describes (`TerminalKeyframeHold` in `FyolodClient.swift`). The daemon sends
  `S` before `E resized` by construction, so no client-side ordering wins that
  race — **do not reintroduce "let the surface lead its declaration"**, it was
  tried and it cannot work.
- **The letterbox stays pinned for the whole drag.** `viewportPending` is gone.
- **A client-requested resync is answered.** `ResendSnapshot` used to ask the
  sidecar for a capture without opening the barrier, so `finish_snapshot`
  discarded every answer as stale.
- **Focus reports (`ESC [ I` / `ESC [ O`) are device reports**, not typing
  (`TerminalDeviceReport`), and `note_use` deliberately does not stamp on them.
  That was the *old* Mac-vs-phone resize storm; if the storm is back, it is back
  by a new route, not this one.

Also unfixed and known, so don't be surprised by it:

- **iOS still paints keyframes immediately** (`ios/Sources/FyolodSession.swift`
  `repaint`). The hold was never ported to the phone. It gets the mangled frame
  and a repair one round trip later — which at least now arrives.
- **The 45↔46 row oscillation** (§8.4 of the sibling handoff):
  `TerminalGrid.fitting` floors in *points* while libghostty floors in *pixels*.
  Suspected off-by-one, untouched.

## 6. Prime suspects — all four settled

1. ~~**The panes are not attached at all**~~ — no. They were attached, to the
   *release* daemon. See §8.
2. **Two daemons** — **this was it**, and worse than the CLI reading the wrong
   one: the *app* was reading the wrong one. See §8.
3. ~~**The declared viewport disagrees with the surface**~~ — no such
   ping-pong exists. `paneGrid` is computed from `paneSize` (the pane rect, which
   the letterbox does not touch) and `cellSize` (font metrics off
   `context.surfaceSize`, which do not move when the surface is resized).
   Measured across a launch and three divider drags: `cell=9.5x19 scale=2` never
   varied, and every `grid=` followed `pane=` exactly.
4. ~~**The phone's own viewport**~~ — already correct, and
   `MobileViewportFitGeometry.swift` is **cmux's** file, not ours; it was cited
   from cmux in the sibling §7 and does not exist in this repo. fyolo's phone
   declares `hostGrid`, measured from `terminalHost.bounds`, never read back off
   its surface — `ios/Sources/TerminalViewController.swift:326` names the §6.1
   trap in its own comment.

## 7. A separate defect found while chasing this

`CompanionServer.send(_:to:)` wrote the shared `lastRoster` even though it
sends to a single connection, and that same field is `broadcastIfChanged`'s
change detector. The catch-up send on every newly authenticated socket therefore
**consumed** a pending roster change: the socket rendering the phone's project
list never received it and the list stayed stale until the next change.

Fixed on `main` by `22d807e5` — unrelated to sizing, so it went as its own
change. All that is left here is the comment on `send(_:to:)` saying why the
field must not be stamped there, so nobody puts it back.
