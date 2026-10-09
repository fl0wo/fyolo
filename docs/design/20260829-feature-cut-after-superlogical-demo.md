---
title: Feature cut after Superlogical's 28 Aug demo
status: draft
type: rfc
created: 2026-08-29
updated: 2026-08-29
related:
  - 20260817-one-path-local-through-fyolod.md
  - 20260808-sessions-cli-v3-command-design.md
  - 20260825-agent-integration-moves-to-fyolod.md
  - 20260805-fyolod-device-architecture.md
  - 20260824-ios-as-device-client.md
  - 20260719-vibe-island-status.md
  - 20260818-session-guests.md
  - 20260730-fyolod-session-protocol.md
---

# Feature cut after Superlogical's 28 Aug demo

> The comment thread is a demand signal, not a roadmap. This RFC is the cut: four capabilities we already specified and must actually ship, one small product object we do not yet have, and a refuse list so the demo does not grow fyolo into a multiplexer for all work.

**Evidence policy.** Every Superlogical claim below is **Announced** (Mitchell's 28 Aug 2026 demo, https://x.com/mitchellh/status/2093451043661316217, and his replies in that thread) or **Asked** (a comment or quote in that thread). Nothing here guesses at their wire protocol. The architecture comparison is already settled in [device architecture §3 and §7](20260805-fyolod-device-architecture.md) — this RFC does not reopen it.

---

## 0. What this decides

It answers one question: of the features people asked Superlogical for on 28 Aug, **which does fyolo support, in what order, and which existing RFC already owns the work.**

It does **not** decide:

- The hot path. Raw `D` tee, VT as sidecar, `S` only at attach / resize / resync. Settled. Anti-100× stands.
- SSH as a pipe, never embedded crypto. Settled. Their "Smuggling Contraband over SSH" (**Announced**, not initial release) is the hole we keep.
- Layout. Panes, tabs, tiling, copy-mode stay client concerns (§H #5).
- Scope. "Multiplexer for all work" stays a non-goal ([session mux §3](20260730-fyolod-session-mux.md)).

If a proposed feature would put a grid encoder between the PTY and the pipe, re-own the session inside the Mac window, or grow a nested window manager in `fyolod`, it is refused here even if the comment thread wants it.

---

## 1. What the thread actually asked for

241 replies, 103 quotes. Most of the text is "want this" / "tmux in shambles". The asks that survived filtering, grouped:

| Ask | Who | Shape |
| --- | --- | --- |
| Hop machines, session stays alive | @shinzui (Air → Studio), @clinton_cunning (Zellij replacement) | Mitchell: **Yes** / **Yep** |
| Spawn sessions from a CLI / agent, hop in later | @fyzanshaik (orchestrator currently uses tmux), @olvrgln (herdr/pi extensibility) | Mitchell: **"Everything you saw is API driven"** |
| Cross-session "something needs you" | @drucial (OSC notifications, agent waiting, process done) | Mitchell: thinking about a **notification inbox**; "almost all notification inboxes are bad" |
| Remote discovery without assembling tunnels | @tibudiyanto | Mitchell: **integrated Tailscale (tsnet) or manual** |
| Headless Linux server, installable | @sudomateo | Mitchell: **yes, NixOS module; macOS app bundles it for UX** |
| Native iOS client, not SSHish | @felip3fdl | Mitchell: **"Even better, a native client app"** |
| SSH as the only pipe the box will allow | @BenWibking, @bhautiktweets, @gambhir_sharma | Mitchell: **not initial release** |
| Linux desktop client | @0xferrous | unanswered in-thread |
| Tiling / vim copy-mode / tmux chords | @vkoskiv, @damirca, @mattbui27 | unanswered |
| Cmd+F, command palette, floating panel, any shell | @fatih, @guzmonne, @Dankishann, @davidwbrw | Mitchell: already yes / any shell |
| Open source, pricing, k8s pods | several | unanswered, or "Mmhmm" |

The thread's buying reason is not a feature list. It is **durable sessions that feel native, without learning tmux**, plus **an agent that can create and watch those sessions**. That is already fyolo's thesis. The work is to stop implementing it against the object the Mac happens to hold.

---

## 2. The cut

Four buckets. "Ship" means user-visible on both the local Mac path and a `fyolod` path. "Specified" means an existing RFC already owns it — this document does not re-spec it. "Refuse" is load-bearing: a later PR that sneaks one of these in has to reopen this RFC, not "just add the control".

| # | Capability | Bucket | Owner |
| --- | --- | --- | --- |
| C1 | Session lives on the device. Detach ≠ kill. Air → Studio is reattach, not a new PTY | **Ship** | [One path](20260817-one-path-local-through-fyolod.md) |
| C2 | `fyolo sessions spawn` / `run` / `watch` / `send` against the host, returning `fyolo://session/<uuid>` | **Ship** | [Sessions CLI v3](20260808-sessions-cli-v3-command-design.md) |
| C3 | `working` / `idle` / `needs-you` / `done` is a protocol object on every session, including fyolod | **Ship** | [Agent integration → fyolod](20260825-agent-integration-moves-to-fyolod.md); the live bug is one-path inventory row 5 |
| C4 | A box that only speaks SSH is still reachable, as a terminal, without installing `fyolod` | **Ship** (keep the hatch, do not grow a second workspace plane) | One path §1, "three session kinds" |
| C5 | A `needs-you` names the session and takes you there — Mac roster, menu bar, CLI `watch`, later the phone | **Ship** (the one new object, §4) | this RFC |
| C6 | One device connection, N sessions as channels | **Later** | [Device architecture §5](20260805-fyolod-device-architecture.md) |
| C7 | Phone attaches to the device, not to the Mac | **Later** | [iOS as a device client](20260824-ios-as-device-client.md) |
| C8 | Optional Tailscale (or equivalent) discovery provider | **Later** | Device architecture §2; not a protocol change |
| C9 | Guest attach / live sharing | **Later, product call** | [Session guests](20260818-session-guests.md) — already "whether this ships at all is a human call" |
| — | Tiling WM in the host, vim copy-mode as protocol, tab-icon theming, floating-panel product, k8s-as-v1, web-first, SSH smuggling, a chronological notification inbox, speaking Superlogical's unpublished protocol | **Refuse** | §6 |

C1–C4 are not new ideas. They are the comment thread pointing at holes we already named. C5 is the only thing this RFC adds.

---

## 3. Ship — the four capabilities, as they actually stand

### C1. Sessions live on the device

The demo's "Yes" to Air → Studio is detach ≠ kill. Fyolo already decided this. The Mac still allocates `PTYProcess` for local sessions, so quitting the app still kills the work, and a fyolod session is a second kind of object with missing halves.

Do not start a third "remote session" type. Finish one-path: every PTY is `fyolod`'s; the app is a viewer. The test remains device architecture §4.1: *would two people watching this session from two machines expect the same answer?* Yes → the device owns it.

### C2. Spawn without tmux

@fyzanshaik's orchestrator currently opens Claude/Codex via tmux so a human can hop in. That is the exact sentence `fyolo sessions spawn` was written for ([CLI v3](20260808-sessions-cli-v3-command-design.md) §0: links not coordinates, JSON not format strings, `watch` not poll).

The verb exists today (`scripts/fyolo` → app control socket → `FyoloStore+SessionControl.swift`). Two gaps make it not yet the product the comment asked for:

1. It talks to the GUI. A spawned session dies with the app. C1 fixes the lifetime; C2 then has to route P-verbs at `fyolod` as v3 already scheduled, not keep a second vocabulary on the app socket.
2. Placement flags (`--direction right|down`) are GUI. They stay **G**-verbs (`focus`, split). An orchestrator agent must be able to `spawn` with no window present, get a link, and `watch`. Hopping in is `focus` or a later attach, never a requirement of `spawn`.

Acceptance: from a shell that is not inside fyolo, `fyolo sessions spawn "fix the build" --agent claude --json` returns a link; `fyolo sessions watch <link> --json` emits status without the Mac app holding a `PTYProcess`; quitting the app does not close the session.

### C3. Status on the wire, on every session

@drucial asked for OSC notifications across sessions. Mitchell reached for an inbox. Fyolo already has the better object: workstream status. Vibe Island ([done](20260719-vibe-island-status.md)) wired OSC 9/99 and hooks into `idle` / `working` / `needsAttention` — against `PTYProcess`. One-path's inventory is still true as of this writing: the detector sits inside `if let pty` (`FyoloStore+TerminalSurface.swift`), so a fyolod session never changes its icon.

C3 is that bug, treated as a feature gate. Status is produced on the host ([agent integration moves into fyolod](20260825-agent-integration-moves-to-fyolod.md)), fanned out as events, and displayed by every client. Heuristic OSC remains a fallback, not the authority.

Acceptance: a Claude session started via C2 on a local `fyolod` flips `working` → `needs-you` → `done` in `fyolo sessions list --json` and in the Mac sidebar, with `pty == nil`.

### C4. The SSH hatch stays a hatch

The thread's SSH ask is two different things, and mixing them is how this cut fails:

- **Transport to a box that runs `fyolod`.** System OpenSSH (or Tailscale) as the pipe. Keep. This is the trust choice Superlogical is *not* making for v1.
- **A session whose command is `ssh <host>`**, because you cannot install anything on that host. Keep as a terminal. Do not rebuild SFTP / git-over-SSH as a second workspace plane (one-path §1 already killed that). The panel names the gap and offers `remote deploy`.

Do not add an "SSH extension" or a Superlogical-style tunnel-smuggler to satisfy @bhautiktweets. The hatch is three lines of argv. Growing it re-forks the product.

---

## 4. The one new object: `needs-you` routing

Mitchell's words: *"We've described it as a notification inbox. But almost all notification inboxes are bad."* Agree. Do not build one.

What the comment actually wanted is: *an agent waiting on a session I am not looking at becomes something I can act on without hunting.* Fyolo already has the state (`needs-you`). What it does not have is a single routing rule that works once sessions no longer live in the focused window.

**The object is a roster event, not a feed.**

```
needs-you { session, title?, reason? }
```

`session` is `fyolo://session/<uuid>`. `reason` is optional and coarse (`approval` / `question` / `bell`) — never a transcript excerpt, never a toast body copied from the screen. One event per transition into `needs-you`, not per OSC 9.

**Where it surfaces** (nothing here is a new surface; it is a destination for an event we already show badly):

| Client | What happens |
| --- | --- |
| Mac, app focused | Existing status dot and menu-bar pulse. Click / `focus` the link. Command palette already searches sessions — that is the jump, not a new inbox pane |
| Mac, app in background | Existing user notification, payload is the link. Click focuses that session. No grouping, no "3 agents need you" rollup in v1 |
| `fyolo sessions watch --state needs-you` | The same event on stdout. This is the orchestrator surface; it already exists in v3's spec |
| iOS | Same event, once C7 lands. APNs-while-closed stays the open question in [remote-to-device §7.6](20260814-remote-to-device.md) — unsigned, no hosted control plane. C5 does not block on it |

**What we refuse to add in the name of this object:**

- A chronological inbox of bells, completions, and "process done elsewhere"
- Per-agent notification preferences beyond mute-this-session
- A badge count that mixes `working` and `needs-you`
- Routing through the Mac when the phone could attach to the device (that is C7, not a notification design)

C5 is blocked on C3. Shipping an inbox against `PTYProcess.lastBellAt` would re-fork the same detector one-path is deleting.

---

## 5. Later — do not start these from this thread

C6–C9 are real, and Superlogical is demoing several of them. They are not the cut, because each is already owned and each is blocked on C1.

- **C6 device connection.** Their mux "owns SSH" as a durable resource. We agree on ownership, not custody (device architecture §5.1, §7). One `ssh` per session in `FyolodClient.swift` is the gap. Fix it after local sessions are already host-owned, or the reconnect story only works remotely.
- **C7 iOS as device client.** Native client was the highest-engagement product reply in the thread (96 likes on "Even better, a native client app"). The phone is still a Mac mirror. That RFC exists. Companion wire deletion is its last step, not a demo reaction.
- **C8 discovery.** tsnet-or-manual is a product wrapper around finding a `HostRef`. Provider interface is specified, not built. Optional; a Tailscale account must not become required to attach.
- **C9 guests.** Mitchell: multiplayer is **"Already yes"**. Ours is three deltas and a human call. Not v1.

Web UI, Linux desktop client, and k8s-as-a-session-source are not scheduled here. Web already has a client RFC; Linux desktop is unanswered for them too; k8s is a host, not a session kind.

---

## 6. Refuse

Pulled from the same thread, so a future "users asked for this" cannot reopen them quietly.

| Asked | Why no |
| --- | --- |
| Tiling window manager / i3-in-the-app | Layout is a client concern. Native panes already exist. A host that owns tiles is the nested WM §H #5 forbids |
| Vim copy-mode, yank, tmux prefix chords as protocol | Native selection and search beat copy-mode. Keybindings stay in the app ([keyboard command design](20260812-keyboard-command-design.md)). CLI v3 already refused copy-mode verbs |
| Tab icon theming, floating panel as a product | Cosmetic; do not block C1–C5 on it. If a floating inspector already exists, it is not a mux feature |
| "SSH client or extension" beyond C4 | Rebuilds a second workspace plane for hosts without `fyolod` |
| SSH smuggling / mosh-class UDP in v1 | Trust plane. Eternal Terminal in their comparison blog is their homework, not ours |
| Chronological notification inbox | §4 |
| Speaking their unpublished "open protocol" | No spec, no OSS as of 8 Aug check (device architecture §7). Re-evaluate when it lands, as that section already says |
| Pricing / OSS of Superlogical as a fyolo decision | Not our product. fyolo stays free; `fyolod` stays user-run |
| Multiplexer for all work (CI, prod apps, incident fabric) | Non-goal, restated |

Cmd+F, command palette, session picker, any shell, scrollback search — already yes in the Mac app. They are not work items.

---

## 7. Sequence

Do not fan this out. C2 and C5 are lies until C1 and C3 are true on the same path.

1. **One path** (C1). Local PTY leaves the app. This is the in-review RFC, not a new project.
2. **Status on the host** (C3). Delete the `if let pty` detector. Hooks and `agent report` land on `fyolod`. Sidebar and `list --json` read the same events.
3. **P-verbs default to `fyolod`** (C2). `spawn` / `watch` / `send` / `list` no longer require the GUI to own the session. `--direction` stays G.
4. **`needs-you` routing** (C5). One event, existing surfaces, no inbox. Thin, and only after C3.
5. **C6 device connection**, then **C7 phone**, then **C8 discovery**. In that order. Guests (C9) remain a separate product call.

A PR that implements C5 against the in-app PTY, or C2 as a tmux-shaped `split-window`, is out of order even if it looks like the demo.

---

## 8. What would make this RFC wrong

- Superlogical ships a documented, libghostty-shaped session protocol other clients actually speak. Then device architecture §7's "cheapest path may be speaking theirs" becomes a live question. That is a protocol decision, not a feature add.
- The orchestrator demand turns out to be "drive an existing pane like `tmux send-keys`" and not "create a session, get a link, watch it". We already have `send`. Do not invent a second spawn.
- `needs-you` without a link is shown to be the thing people wanted (a feed of every bell). Then §4 is wrong, and the answer is still not an inbox — it is a better `watch` filter. Reopen this RFC rather than adding a pane.
