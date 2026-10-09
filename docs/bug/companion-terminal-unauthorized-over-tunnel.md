---
title: iOS terminal fails "unauthorized" while the session list works (companion over tunnel)
status: done
type: bug
created: 2026-07-04
updated: 2026-07-04
---

## RESOLVED — confirmed root cause + fix (2026-07-04)

A loopback `tcpdump` of the terminal socket (client→server frames unmasked) showed
the phone sends **`resize` before `auth`**:

```
CLIENT → SERVER (terminal socket):
  1. {"t":"resize","cols":38,"rows":17}
  2. {"t":"resize","cols":38,"rows":17}
  3. {"token":"…","t":"auth"}          ← auth is only the 3rd frame
  4. {"t":"attach","session":"A4FE…"}
  5. {"t":"resize","cols":38,"rows":17}
SERVER → CLIENT:
  {"t":"error","message":"unauthorized — scan the QR code in Settings ▸ Mobile"}
```

The server refuses any non-`auth` control on an unauthenticated connection
(`CompanionServer.swift:240-242`), so the leading `resize` trips "unauthorized"
before `auth` is read. **Cause:** `CompanionTransport.resize()` → `sendGrid()`
does `task.send(...)` as the terminal view lays out — after `task.resume()` but
before `didOpen`. URLSession queues those `resize` frames and flushes them *ahead*
of the `auth` that `didOpen` sends. The roster socket (`CompanionClient`) only ever
sends `auth`, which is why the list worked and the terminal didn't.

**Fix** (`ios/Sources/CompanionTransport.swift`): an `authSent` gate (guarded by
`gridLock`). `sendGrid()` and keystroke `send()` transmit nothing until `didOpen`
has queued the `auth` preamble and set `authSent = true`; `connect()` resets it to
`false` on every (re)connect. Early `resize`/keystroke frames are suppressed
(the grid is re-sent right after auth in `didOpen`), so `auth` is always first.

The everything below is the original investigation, kept for context.

---

# iOS terminal fails "unauthorized" while the session list works (companion over tunnel)

> The iPhone pairs and shows the live session **list**, but opening any session's
> **terminal** fails with *"Companion connection failed — unauthorized — scan the
> QR code in Settings ▸ Mobile"*. Re-scanning the QR does not help. Reproduces
> only against the real phone over the Cloudflare tunnel; not from a scripted
> client, and not on the Mac loopback.

## Symptom

1. Pair the iPhone to the Mac (Settings ▸ Connectivity, scan QR). Connection is a
   `cloudflared` quick tunnel (`wss://<random>.trycloudflare.com?t=<token>`).
2. The session **list** loads and shows live sessions/status → the roster socket
   is connected and authenticated. ✅
3. Tap any session to open its **terminal** → red alert **"Companion connection
   failed"**, reason **"unauthorized — scan the QR code in Settings ▸ Mobile"**. ❌
4. Re-pairing (re-scanning the current QR) does not fix it.

## Architecture context (why "list works, terminal doesn't" is meaningful)

The list and the terminal are **two separate WebSocket connections** to the same
companion server, each authenticating independently:

- **List** — `CompanionClient` (`ios/Sources/CompanionClient.swift`): opens the
  socket, sends `auth`, receives the roster. This works.
- **Terminal** — `CompanionTransport` (`ios/Sources/CompanionTransport.swift`):
  opens a **second** socket, on `didOpen` sends `auth`, then `attach`, then the
  grid `resize` — then bridges PTY bytes. This is the socket the server refuses.

Both are created from the **same** `companionURL` (the saved roster URL, carrying
`?t=<token>`), so in principle both present the same token.

## Server refusal paths (which "unauthorized" is this?)

`Sources/fyolo/CompanionServer.swift`:

- **Bad token** (`handle`, ~L233): `"unauthorized — re-scan the QR code on your Mac"`.
- **Unauthed control** (`handle`, ~L241): an `attach`/`resize` arrived on a
  connection not yet in `authed` → `"unauthorized — scan the QR code in Settings ▸ Mobile"`.
- **10s auth grace** (`accept`, ~L173–177): connection didn't authenticate within
  ~10s → same `"…scan the QR code in Settings ▸ Mobile"`.

The observed text matches the **unauthed-control** or **grace-timeout** paths, NOT
the bad-token path. So the token the phone holds is fine (consistent with the list
working) — the terminal socket's `auth` is either **not arriving/registering** or
being **overtaken by `attach`** on the server.

## What has been ruled out

- **Server logic is healthy.** Reproduced the phone's exact `auth → attach → resize`
  handshake from a Python client:
  - over **loopback** ws://localhost:8787 — 35+ runs, 0 failures (PTY bytes stream);
  - over the **real cloudflared tunnel** (`wss://…trycloudflare.com?t=…`) — 20/20
    OK, even firing `auth`+`attach`+`resize` back-to-back with no delay, while
    holding a second roster socket open (mirrors the phone's two-socket state).
- **Stale iPhone build missing terminal auth** — ruled out: session-socket `auth`
  was added in the **same commit** as roster `auth` (`72c7db8`, "gate the companion
  link behind a pairing token…"). Since the list works, the installed build has the
  terminal-socket auth too.
- **Tunnel churn / stale URL** — a *contributing* environmental issue (see Related
  fix), but the bug still reproduces with a single clean tunnel and a fresh pairing.

## Leading hypotheses (unconfirmed)

1. The terminal socket's `auth` frame does not reach / register at the server
   before its `attach`, so the server refuses on the unauthed-control path. Only
   the phone's `URLSessionWebSocketTask` send timing (three un-awaited sends in
   `didOpen`) differs from the scripted clients that pass — not yet reproduced.
2. The server dispatches each control on a separate `Task { @MainActor in … }`
   (`receive`/`handle`), which does not guarantee FIFO execution; a burst
   `auth,attach,resize` could run `attach` before `auth` sets `authed`. Stress
   tests haven't triggered it, but the phone's burst timing may.
3. The terminal socket is somehow not sending `auth` at all (would hit the 10s
   grace). Needs client-side confirmation.

The decisive discriminator is **client-side truth**: does the terminal socket put
an `auth` frame on the wire, and what does the server reply? Timing also tells:
**immediate** failure ⇒ unauthed-control (auth missing/late vs attach);
**~10s delayed** failure ⇒ grace timeout (auth never arrived).

## Diagnostic — capture the plaintext frames on the Mac (definitive)

`cloudflared` connects to the server over **plaintext ws on loopback**
(`127.0.0.1:8787`), so the terminal socket's actual frames can be recorded on the
Mac without touching the phone. (Device-side `log collect --device-udid` returned
"Device not configured (6)" over both Wi-Fi and USB on this setup, so the wire
capture is the reliable path.)

Run this, then **tap a session on the phone** during the 30s window so it fails:

```sh
sudo sh -c 'tcpdump -i lo0 -s0 -w /tmp/companion.pcap "tcp port 8787" & TP=$!; echo "CAPTURING 30s — TAP A SESSION ON YOUR PHONE NOW, let it fail"; sleep 30; kill $TP; echo CAPTURE_DONE'
```

Then decode `/tmp/companion.pcap` (`tshark -r /tmp/companion.pcap`, or a WebSocket
decoder — client→server frames are RFC-6455 masked, so unmask with the 4-byte key
to read the JSON, or just count/size the client frames: `auth`≈50B, `attach`≈55B,
`resize`≈35B). On the terminal's (second) connection, confirm:
- how many client→server frames it sends — 3 (`auth`+`attach`+`resize`) vs 2 (no `auth`);
- what the server sends back — a `roster` frame (auth accepted) vs an `error`
  frame then close (refused).

### Supporting commands used during investigation

```sh
# Current pairing token and tunnel URL (values rotate on each app relaunch):
defaults read sh.fyolo.app companion.pairingToken
grep -iE "\[tunnel\] up at" /tmp/fyolo-dev.log | tail -1

# Live connections to the companion port (roster vs terminal vs tunnel vs sim):
lsof -nP -iTCP:8787

# Reproduce the phone handshake through the tunnel (should stream PTY bytes):
#   pip3 install websockets ; then a client that connects to
#   wss://<tunnel-host>?t=<token>, sends {"t":"auth","token":…},
#   reads the roster, then on a 2nd socket sends
#   {"t":"auth"…}{"t":"attach","session":<id>}{"t":"resize","cols":80,"rows":24}.

# iOS device log (needs the device "configured"/reachable; failed here):
xcrun devicectl list devices           # get the iPhone UDID
sudo log collect --device-udid <UDID> --last 10m --output /tmp/iphone.logarchive
log show /tmp/iphone.logarchive --predicate 'process CONTAINS[c] "Fyolo"' --info \
  | grep -iE "companion|pairing token|unauthor|attach|auth"
```

The phone-side smoking gun, if the log can be pulled, is the NSLog added in
`CompanionTransport`/`CompanionClient`:
`"[companion] session URL has no pairing token (?t=…) — the Mac will refuse this
socket after ~10s."` — if it fires, the terminal socket's URL is missing the token.

## Related (already shipped, uncommitted)

Separate but adjacent: `cloudflared` quick tunnels mint a **new URL every start**
and the old tunnel was orphaned on `pkill -9`/crash (reparented to launchd),
leaving the phone pinned to a stale URL. Fixed with
`TunnelManager.reapStrayTunnels()` (SIGKILL any tunnel on port 8787 before
spawning) + the same `pkill` in the `macos-rebuild-dev` skill. This makes the
setup converge to one tunnel per launch but does **not** fix this auth bug.

## Next steps

1. Capture `/tmp/companion.pcap` (above) and decode the terminal socket.
2. If `auth` is missing on the wire → fix the client (ensure the terminal URL
   carries `?t=` / the transport always sends `auth`).
3. If `auth` is present but refused → fix the server ordering: make `attach`
   tolerate arriving with/just-before `auth` (e.g. serialize control handling per
   connection instead of one detached `Task` per frame, or queue non-`auth`
   controls until `authed`), and/or widen the grace / re-send `auth`.
