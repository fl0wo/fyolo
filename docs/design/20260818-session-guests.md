---
title: Session guests — three deltas, not a sharing subsystem
status: draft
type: design
created: 2026-08-18
updated: 2026-08-24
related:
  - 20260818-fyolod-web-client-ghostty-wasm.md
  - 20260730-fyolod-session-protocol.md
  - 20260628-session-share.md
  - 20260805-fyolod-device-architecture.md
  - 20260805-fyolod-hot-path-and-client-classes.md
---

# Session guests — three deltas, not a sharing subsystem

> Every client attaches to the device that owns the session. A colleague's browser is one more such client, never a viewer of the owner's viewer. Under that rule the protocol already carries almost all of live sharing — `mode: observe`, single-writer newest-claim, the `writer_changed` fan-out, authoritative dims with client-side letterboxing. What is genuinely new is small enough to name: a **scoped guest credential**, **reachability for someone on neither the tailnet nor ssh**, and the owner's **consent and audit UI**. Plus one thing that hides inside the first and must not: **an enforcement seam for a connection whose authorization is narrower than the daemon's.**

**Date:** 2026-08-18
**Status:** Draft. Whether this ships at all is a product call the [open questions](#open-questions-for-a-human) leave to a human.

---

## What this decides

[Session protocol](20260730-fyolod-session-protocol.md) §F #3 says sharing with an external identity is out of protocol v1 and "needs a pairing/ACL design that must not be improvised." This is that design, and its main finding is a subtraction: **there is no sharing subsystem to build.**

The reason is the model, not luck. Every UI is a client of the device that owns the session ([device architecture](20260805-fyolod-device-architecture.md) §2.1): web to `fyolod` on Linux, web to `fyolod` on a Mac, iOS the same, **never through another viewer**. The current iOS path — the phone mirroring a Mac viewer that holds a `PTYProcess`, over `CompanionServer` + `WireProtocol` (2,092 lines) — is the shape §H #9 condemns as "a second protocol for the phone," and it is the thing being retired, not the pattern a guest should copy. Once a guest's browser is a direct client, sharing is mostly a matter of *which* client is allowed to say what.

So this doc is structured as: what already carries sharing, then the three deltas, then the fourth thing that hides inside delta one.

## What already carries sharing

Every row here is shipped mechanism. None of it is re-designed below.

| Sharing requirement | The mechanism that already carries it | Source |
| --- | --- | --- |
| A second person watches without disturbing the session | `Control::Attach { mode: Observe }`; observers never claim the token | §C.5, `protocol.rs` `AttachMode` |
| Exactly one person can type | Single writer, newest `interact` claim wins, previous writer demoted but still attached | §C.5, `session.rs` `recompute_writer` |
| Handover is visible to everyone, not just the owner | `Event::WriterChanged` fans out to every attachment | `session.rs` `emit_writer_changed` |
| An observer's stray keystroke cannot leak through | Observer `D`/`R` answered `error { code: "not_writer" }` | §C.5 |
| The guest's window is a different size than the owner's | Authoritative `rows`/`cols` on `Attached` and `Resized`; the client letterboxes and never reparses at its own size | §C.5 |
| The guest sees the current screen, not a torn replay | The JOIN barrier: one `S` at an exact boundary, then live `D` | §C.5 |
| The guest's theme is the guest's | `palette: false` on `S`; the renderer resolves tagged colours from the viewer's palette | web-client RFC, Goal 4 |
| The guest reaches the box over a browser-compatible pipe | Loopback WSS inside `fyolod`, TLS in Tailscale Serve or Caddy, Origin allowlist | web-client RFC |
| Guest joins and leaves without touching the session | Detach ≠ kill; channel death is detach | §C.5 |
| The owner refuses an operation | `ErrorCode::Denied` is already in the closed vocabulary | §C.7 |
| Multiple viewers cost the host nothing structural | Raw `D` fan-out; the VT sidecar is not per-viewer | §A anti-100× invariant |
| Sharing plugs into the write token, not into merged input | Stated in §C.5; CRDT rejected in §H #5 | §C.5, §H #5 |

That is the feature. What is missing is who is allowed to hold it.

---

## Delta 1 — a guest credential, scoped to one session

The owner's `pair.token` is the wrong credential and not by a small margin: it is per-device, minted only by `fyolod pair`, and scoped to **the whole daemon**. Handing a colleague a copy is not a share, it is a giveaway.

A guest grant is a second credential class:

```
state_dir()/guests/<sha256(token)>.json      mode 0600, dir 0700
{
  "session_id": "s_41",
  "may_type": false,
  "label": "code review with Alex",
  "created_unix": 1786000000,
  "expires_unix": 1786003600,
  "max_attachments": 2
}
```

- **24 random bytes, base64url** — same shape and generator as `pair.token`. Only the hash is stored, so a `tar` of the state dir is not a pile of live shells. The cost is that a link **cannot be re-displayed**, which is correct behaviour and matches every credential UI worth copying.
- **Presented exactly like the owner's token:** `Sec-WebSocket-Protocol: fyolod.<token>`. The accept path hashes what it was given, checks `pair.token`, then the guest directory. No wire change. The page bootstraps from `https://<box>/fyolo/#g=<token>` (a distinct hash key so the page can render guest chrome before any frame), reads it once into `sessionStorage`, clears the hash. `?t=` / `?g=` on `/ws` stay refused.
- **Expiry is absolute and short.** Default 1 hour; the UI offers 1 / 8 / 24 and nothing longer. There is no "never expires".
- **Four ways a grant dies:** expiry; the owner ends it; the session exits (the record is unlinked with the tombstone); `fyolod share revoke --all`.
- **Revocation is the `notify` watch the RFC already specifies** for `pair.token` rotation, pointed at `guests/` as well: on change, every splice carrying that grant closes. Detach, not kill — the session is untouched.
- **`max_attachments` defaults to 2**, not 1. One is too strict (a reloading browser races its own closing socket); two lets the colleague reload and makes a third viewer visible as an anomaly rather than invisible as noise.

`fyolod share <session> [--type] [--for 1h] [--label TEXT]` mints and prints the URL once. `share list` shows label / session / may-type / expiry / live attachments, never the token. `share revoke <id> | --all` unlinks. `pair --rotate` gains one line — how many guest grants are live — because rotating the owner's token does **not** revoke guests and an operator will assume it did.

## The fourth thing, and why the existing mechanism cannot carry it

**A connection whose authorization is narrower than the daemon's does not exist today, and `mode: observe` is not it.**

This is not a fourth *feature*. It is the load-bearing half of delta 1, and it has to be named separately or it will be estimated as "a token file" and reviewed as nothing.

Authorization today is binary and connection-level at every pipe: Unix socket → filesystem permissions, SSH stdio → the identity `sshd` already checked, WSS → `pair.token`. Reach the channel and you can do everything. `mode: observe` is a **writer-policy mode the client chooses for itself**, not a permission: a client that attaches observe can equally open a second channel with `mode: interact`, `create` a session, `fs_read` any file the uid can read, `git_diff`, `send` bytes into an unrelated session, or `kill`. So a credential meaning "observe, on session `s_41`, until 15:00" has nowhere to be enforced.

**Where it goes.** Not the splice. The WSS handler copies bytes onto a connected `UnixStream` and understands no frames — correct, and the reason a guest gate cannot live there: filtering control ops in the transport puts session semantics in the pipe and duplicates the op vocabulary somewhere it will drift. The authorization travels **in-process, beside the bytes**, which is exactly how the other two pipes already work:

```rust
// shape, not a shipped API
enum AuthContext {
    /// Unix socket, SSH stdio, or WSS with pair.token. Full daemon scope.
    Owner,
    /// WSS with a guest grant. Everything not named below is denied.
    Guest { session_id: String, may_type: bool, grant: GrantId },
}
```

`handle_conn` takes the stream generically (`impl AsyncRead + AsyncWrite`, or a `DuplexStream` for the WSS case) plus a context. Two properties earn the refactor:

- **Fail closed.** The process that reads the grants is the process that enforces them, so a build without the gate cannot honour a grant — and refuses to mint one.
- **Default deny, by construction.** The guest arm ends in `_ => denied`, so a control op added next quarter is denied to guests until someone deliberately lists it. That one line is what keeps this from rotting as the protocol grows.

The complete guest ACL — a reviewable list in one file:

| Op | Guest | Note |
| --- | --- | --- |
| `hello` / `hello_ok` | allowed | Caps intersected as usual, **minus `scrollback`** |
| `list` → `sessions` | allowed, filtered | Exactly one `SessionInfo` |
| `attach` (grant target, `observe`) | allowed | The default |
| `attach` (grant target, `interact`) | allowed **iff** `may_type` | Else `denied` |
| `attach` (any other target) | `denied` | Not `no_such_session` — do not confirm what else exists |
| `detach` | allowed | |
| `subscribe {events:["status"]}` | allowed, filtered | Only the granted session |
| `D` / `R` upstream | writer only | Already `not_writer` for observers |
| everything else | `denied` | `create`, `kill`, `send`, `wait`, `set_status`, `subscribe_resource`, `fs_*`, `git_diff`, `upload_*`, and anything added later |

Two consequences fall out of the seam rather than needing designs of their own:

**No scrollback for a guest.** Capability intersection is already the host's decision at `hello`; the guest context refuses `scrollback`, so no `H` is staged. That matters: the normal attach would ship up to `SCROLLBACK_STAGE_MAX_BYTES` (1 MiB) of prior scrollback — earlier commands, printed environment, file contents, a key an agent echoed — which is a far larger disclosure than the screen. The guest sees the screen from the moment they join, and forward. **The honest limit, stated in the UI too: the program can reprint anything.** `history`, a TUI repaint, an agent re-rendering earlier turns. No host rule prevents that.

**Withdrawing permission demotes a live guest.** Clearing `may_type` writes the grant file; the watch fires; the daemon clears that client's `interactive` flag and calls `recompute_writer`, which promotes the owner and fans out `writer_changed`. Existing functions, new trigger.

### Write access, in the mechanism that exists

Two gates, and the first one is the deliberate act. `may_type` is off at mint, is not remembered as a preference, and is a separate switch from creating the link. With it on, the guest's browser attaches `mode: interact` and the **ordinary** writer policy applies — newest claim wins, `writer_changed` fans out.

That yields three properties worth stating, because they are what makes typing safe enough to consider at all:

- **The owner is never locked out.** Taking input back is a `claim_writer` from the owner's pane — typing sends one — and the newest claim wins, so the owner always beats the guest's earlier claim. (Attaching is not a claim: a guest merely *opening* the session cannot take the token, or the owner's window would go read-only at a stranger's grid without anyone typing.)
- **Handover is visible to everyone.** `writer_changed` is a fan-out event, so the guest's page and the owner's pane header show the same fact from both sides.
- **Nothing new is invented.** Take input / Release is already specified in the web-client RFC as "close the observe socket, open an interact one."

CRDT and multi-caret input stay rejected (§H #5) and are not reconsidered.

### Blast radius, plainly

**An observing guest reads everything the session prints** — environment dumps, an API key an agent echoed, file contents, `git remote -v`, paths that name the employer. Observation alone is a real disclosure and expiry does not reduce what is on screen now.

**A typing guest has the owner's shell on the owner's machine.** They can read `~/.ssh/id_ed25519`, read agent credentials in `~/.claude` or `~/.codex`, write and push, reach the box's network, and use `sudo` wherever it is passwordless. The Seatbelt sandbox was removed on purpose — agents own their sandbox — so there is nothing between a guest's keystroke and the machine.

The sentence that belongs in the sheet and in the docs: **inviting a guest who can type is equivalent to giving that person an SSH login as you, for the life of the link.**

What constrains it: the default (off), the clock (1 hour), revoke and take-back (one click each, both immediate), scope (one session, no second session to work around the one you are watching), and the advice a UI can give but a daemon cannot enforce — invite into a worktree session, not the one where you keep credentials.

What does **not** constrain it, so nobody plans around it: command filtering, a read-only PTY trick, an audit that would let you undo damage, or any claim that observe-only is risk-free.

---

## Delta 2 — reachability for a colleague on neither the tailnet nor ssh

§F #4 permits a relay on exactly this case, as a **blind pipe**: no session semantics, no `hello` termination, and docs that say plainly which legs see plaintext. The finding here is that **a blind pipe already exists and we do not have to build one.**

**Recommended: Tailscale Funnel.** Tailscale's own documentation is explicit that the ingress does not decrypt: *"The Tailscale server running on your device receives the encrypted request from the TCP proxy. It then terminates the TLS connection and passes the decrypted request to the local service"*, and *"Funnel relay servers do not decrypt the traffic between public devices and your device. This ensures that Tailscale cannot access or read any content."* That is §F #4's blind pipe, built, and audited by someone else.

```sh
tailscale funnel --bg --set-path=/fyolo http://127.0.0.1:8790
```

Funnel listens only on 443, 8443, and 10000, and must be enabled for the tailnet in the admin console — real friction for a colleague-sharing feature inside a company, and it belongs in the docs rather than in a support thread.

Which legs see plaintext, for every option:

| Front | Terminates TLS | Sees session bytes | Verdict |
| --- | --- | --- | --- |
| Tailscale Funnel | `tailscaled` on the box | The box and the browser only | **Recommended** |
| The operator's own Caddy / nginx, same box | That process, same uid | The box and the browser only | Fine |
| The operator's own `cloudflared` / tunnel | Cloudflare's edge | **Cloudflare sees plaintext** | Allowed, must be labelled |
| A relay Fyolo runs | Us | **We would see plaintext** | Rejected — not built, not planned |

`CreateSpec.env`, `argv`, and `D` may not cross a third-party relay in the clear (§C.8). Funnel and a same-box proxy satisfy that; the `cloudflared` path does not, so the docs name it and the UI does not recommend it.

**When would we actually build a relay?** Only for a user with no tailnet, no domain, and no admin rights — and only as a blind TCP pipe with a named trigger, not as part of this work. If that case gets built, the rule is fixed in advance: it forwards bytes, terminates no `hello`, holds no session state, and its existence is documented as "Fyolo's relay sees ciphertext only." Anything more is a control plane and is refused.

**Minting a grant is not the same as making the box reachable, and the UI must never blur the two.** The daemon already knows its public origin because the operator had to declare it (`--wss-origin` / `FYOLOD_WSS_ORIGIN` is required behind any terminator), so the link's base URL **is** `--wss-origin`. No probing, no `tailscale status` shell-out, no new config. With no public origin, the sheet says so instead of handing out a `127.0.0.1` URL.

**The page comes from the box. Always.** `index.html`, the bundle, and `ghostty-vt.wasm` are served from the box's `--web-root` or the operator's proxy in front of it. Hosting the app on fyolo.sh would mean whoever controls fyolo.sh controls the code inside every shared session — a supply-chain hole for a shorter URL. fyolo.sh documents the feature; it never serves it.

**Funnel publishes the box's `ts.net` hostname**, including into certificate-transparency logs. Anyone who reaches the URL gets the static page and never a session (an unauthenticated Upgrade gets silence and a short close). Name that before someone finds it in a CT feed.

---

## Delta 3 — consent and audit, on the owner's side

### Where the affordance lives

The share starts where the session lives: the session row in the left sidebar.

**Not in the ＋ menu.** Every ＋ item must be globally applicable; a verb acting on one specific session follows focus, and focus-following verbs belong to ⌘T, the File menu, and the command palette. The row menu today is `Rename…` · `Copy Session Link` · — · `Ungroup` / `Group with ▸` · — · `Pin` · — · `Close Session` (`SidebarView.swift:1093`). The new item joins the first group, next to `Copy Session Link`, because both hand this session to someone else:

```
Rename…
Copy Session Link
Invite a Guest…            ← new; while a guest is attached: End Guest Access
────────────
Group with ▸  /  Ungroup
────────────
Pin
────────────
Close Session
```

`Group with`, `Ungroup`, and `Close Session` keep their exact wording. "Close Pane" and "Unsplit" stay dead.

**The item exists only for a fyolod-hosted session** (`Session.fyolodRemoteHost`, or a local fyolod host). A grant is minted and enforced by a daemon; an in-app PTY has no daemon and nothing to mint. That is a real limit of the feature, not a temporary gap.

### The sheet

One sheet, two controls, one button. The subtext says what the control does; the second sentence says what it costs.

> **Invite a Guest**
>
> A guest opens this session in a browser and watches it live. They see the screen from the moment they join, and nothing that scrolled past before.
>
> **Link expires** [ 1 hour ▾ ] · 1 hour · 8 hours · 24 hours
>
> ☐ **Let the guest type**
> The guest sends keystrokes to this session, the same as you. Anything you can do here — read your files, read your keys, run commands — the guest can do too.
>
> [ Cancel ] [ Create Link ]

After minting:

> **Copy Link** — `https://box.tailnet.ts.net/fyolo/#g=…`
>
> This link is shown once. If you lose it, create a new one — the old link stops working.

With no public origin configured:

> This session's host has no public address, so a guest link wouldn't open anywhere. Set one with `--wss-origin` and try again.

While a guest is attached, the row carries a **1 guest** badge and the pane header says who holds input:

> **Guest has input** [ Take Input Back ]

From the row menu:

> **End Guest Access** — closes the guest's connection and stops the link working. The session keeps running.

Every string above is a draft; run `review-copy` before any of it ships, and prefer whatever the equivalent System Settings pane already says.

### The guest's page

The web client from the RFC with guest chrome: no session list (there is one session and it is open), the writer/observer badge unchanged, Take input shown **only** when the grant allows it (never a control that will answer `denied`), the theme toggle kept (a guest is a viewer and the palette is theirs), and two distinct end-states — *The owner ended this share.* for a rejected Upgrade, the ordinary reconnect banner for a transport failure. A page that retries a revoked grant forever reads to the owner as a revoke that did not work.

### Audit — and the one place "it already exists" does not hold

Three of the four things an owner wants are already on the wire:

- **How many attachments** — `SessionInfo.attached_clients`.
- **Who holds input** — `SessionInfo.writer_client_id`, plus `Event::WriterChanged` on every handover.
- **What the client says it is** — `Hello.client`, the string every client already sends (`"fyolo-web/0.1.0"`); the guest page can carry the grant's label there so the row reads as the invitation.

**The fourth — "who is attached, from where, and when they left" — the wire cannot answer today, and this is a correction to the premise.** `attached_clients` is a **count**: `session.rs:337` computes it as `self.clients.len()`. `ClientEntry` (`session.rs:227`) stores no name, no attach time, and no peer address. And there is no `client_name` field — `Control::Hello` carries `client: String`, a user-agent string. So the wire can say "2 attached, `c_41` can type" and cannot say "joined 14:02 from 203.0.113.4".

Two ways to close it, and v1 should take the second:

1. **Grow `SessionInfo` additively.** Note the trap: `attached_clients` is a `usize` the Mac already decodes, so it must **not** be re-typed into an array — that is a `proto:1` break dressed as an addition. The detail would have to ride a sibling field.
2. **Answer it off-wire, where the authorization record already lives.** The grant file *is* the audit record — who was invited (the owner's label), when, with what capability, until when. And the RFC already specifies one WSS log line per Upgrade with Origin and outcome, one on a dropped splice, one on rotate; guest Upgrades log the grant id (never the token) and the peer address, and detach logs the same id. That answers "from where" and "when they left" without a byte on the wire.

Recommendation: ship (2), and do not add a per-attachment identity list until someone decides it is worth promising identity that [a bearer token cannot deliver](#the-risk-that-does-not-design-away).

---

## The strategic payoff — does it hold?

The claim: making the browser a direct client of `fyolod` is what lets the companion wire be deleted, because the phone then takes the same path.

**It holds, with one correction and one addition.**

**The correction.** The browser does not delete anything by itself; the *phone* becoming a direct client does. What the browser work buys is that the phone's migration stops being a research project: WSS, the pairing token, the Origin rule, a non-Mac Replica of this protocol, and a renderer seam all get proven by a client that is easy to iterate on. It is a precondition and a rehearsal, not the cause. The guest work adds one more piece the phone needs anyway — a **second credential class on a box**, resolved from a directory beside `pair.token`, which is exactly the shape "one credential per device the phone has paired with" takes.

**The addition: what is left over is not the panes.** Mapping `WireProtocol.swift`'s vocabulary against `protocol.rs`:

| Companion wire | fyolod equivalent | Carried? |
| --- | --- | --- |
| `auth(token, wire)` | `hello` + `pair.token` | ✅ |
| `attach`, `resize`, `stop`, `exit` | `attach`, `R`, `kill`, `Event::SessionExited` | ✅ |
| `start`, `startTerminal` | `create` + `CreateSpec` (`argv`, `env`, `cwd`, `workstream`) | ✅ |
| `listFiles` / `fileList`, `searchFiles` / `searchResults` | `fs_list`, `fs_match` / `fs_search` (§C.12) | ✅ |
| `upload` / `uploaded` | `upload_open` / `U` / `upload_commit` | ✅ |
| `listChanges` / `changes`, `readDiff` / `diff` | `git:` resource subscription (§C.13), `git_diff` | ✅ |
| `error`, `unsupported` | `error`, `proto_error`, additive-ignore rules | ✅ |
| `writeFile(baseMtime:)` / `written` | The upload plane writes bytes to a path — but carries **no mtime precondition**, so the phone's optimistic-concurrency check has no equivalent | ⚠️ gap, small and additive |
| `readFile(dark:)` → `file`, `trace(dark:)` → `traceHTML` | Nothing. The **Mac renders themed HTML for the phone** — a presentation-boundary violation the protocol forbids. `fs_read` returns bytes; the transcript JSONL is reachable as a file | ⚠️ the *rendering* must move client-side |
| `sshConfigHosts` / `sshConfigList` | Nothing. This is **device discovery**, not a session concern | ❌ genuinely absent |

So ~90% of the companion wire is already redundant. What blocks deletion is device-level, not pane-level:

1. **Discovery** — "which `fyolod`, at what address?" The phone currently reads the Mac's `~/.ssh/config` through the wire. The session protocol deliberately has no opinion about this; device architecture parks it under discovery providers. A phone that dials boxes directly needs it.
2. **Per-device credentials and reachability on the phone.** Today there is one pairing and one tunnel, both Mac-shaped. Direct means N boxes, N credentials, N reachability stories — and a box behind a NAT with no tailnet is the same problem as delta 2, for the owner instead of a guest.
3. **Two presentation-boundary violations to unwind** — `readFile(dark:)` and `trace → traceHTML`. Both must become client-side rendering, which is work in the iOS app, not in the protocol.

None of those three is a reason to keep a second protocol. All three are reasons the deletion is a sequenced migration rather than a delete key, and the honest ordering is: web client → guest credential (which proves multi-credential lookup) → phone-direct behind discovery → delete `CompanionServer` + `WireProtocol`. Nothing in this document should be built in a way that assumes the companion wire survives.

---

## This is not the transcript share

[20260628-session-share.md](20260628-session-share.md) is a **different feature** that happens to use the word "share".

| | Transcript share (20260628) | Session guests (this doc) |
| --- | --- | --- |
| What travels | An agent's JSONL transcript, rendered | Nothing. PTY bytes stay between browser and box |
| Where it lives | A server we would run (`web/server`, Hono + Supabase) | Only the box. No backend exists or is proposed |
| Interaction | None, read-only by construction | Observe by default, typing by grant |
| Credential | Unguessable slug, optional bcrypt, `editSecret` | Scoped grant resolved on the box, expiry + revoke |
| Who reads plaintext | Our server, by design | Only the two endpoints, on the recommended front |
| Lifetime | Outlives the session; the snapshot is durable | Useless the moment the session exits |
| Status | Draft, never built — `web/server` does not exist in this repo | Draft, this doc |

**Shared mechanism: none, deliberately.** One publishes an artifact; the other lends a machine. Merging them would put a live PTY behind a credential designed for a public document.

**Vocabulary.** "Share" stays reserved for the transcript link. This feature's noun is **guest**: *Invite a Guest…*, *End Guest Access*, "1 guest". If the transcript feature ships, its verb is *Share Transcript…*.

For "look at what my agent did," the transcript is the *better* answer — no shell, no clock, no blast radius. Guests are for watching a run in progress, or letting someone drive.

## Prior art, briefly

**tmate** hands out one read-write and one read-only `ssh` URL — a distinct credential per capability, decided at mint time, which is the same insight as `may_type`. What we do not copy is the relay: theirs terminates the connection and can read the session. **VS Code Live Share** and **Zed collab** solve identity with accounts on a service they run; we have neither. **opencode**'s share is a slug with no read gate — the floor, not the design. **Superlogical** ships sharing as a headline (**Announced**, mechanism **Unknown**); we do not guess at it.

---

## Alternatives considered

**A. `fyolod pair --guest` — just mint another pairing token.** Rejected: a pairing token's scope is the whole daemon, so this is a shell on every session plus the file and git planes. The scope is the entire feature.

**B. Share a workspace instead of a session.** Rejected for v1: multiplies the blast radius by the session count and pulls the file and git planes into the guest ACL. If ever wanted, it is a second grant kind with its own ACL row, not a widening of this one.

**C. Enforce the ACL in the WSS splice.** Rejected: puts session semantics in the pipe the RFC keeps dumb and duplicates the op vocabulary where it will drift.

**D. A relay Fyolo runs.** Rejected: a hosted control plane, plaintext `D` and `env` on our machines, and the end of the only trust story that survives giving an agent shell access to a private repo. Funnel already does the blind-pipe job.

**E. Host the guest page on fyolo.sh.** Rejected: whoever controls fyolo.sh would control the code inside every shared session.

**F. A time-limited SSH credential for the colleague.** Genuinely secure and genuinely standard, and rejected as *the product* because it requires the colleague to have a key, a client, and the willingness to use them — the audience this feature does not have. It also means Fyolo touching key material, next door to the custody line §F #2(b) refuses. An owner who *can* do this should, and the docs say so.

**G. CRDT or multi-caret typing.** Rejected in §H #5, not reopened.

**H. Screen sharing instead (Zoom, tmate, a shared login).** Worth naming because it is what users do today. Zoom shows pixels and cannot be typed into safely; a shared login is worse than a grant in every dimension; tmate's relay is the thing we reject. "Just use Zoom" is a legitimate answer for a one-off look.

---

## Security & privacy

| Threat | Severity | Mitigation |
| --- | --- | --- |
| Guest link forwarded to a third party | **High** | Not solvable without accounts. Short expiry, one-time display, `max_attachments: 2` so an extra viewer shows in the count, instant revoke. See [the risk](#the-risk-that-does-not-design-away) |
| Typing guest reads `~/.ssh`, agent credentials, pushes code | **High** | `may_type` off by default and named in one sentence; revoke and take-back are one click; no sandbox exists |
| Guest reaches another session or the file/git planes | High | Default-deny op match on `AuthContext::Guest`; a new op is denied until listed |
| Guest reads 1 MiB of prior scrollback | Medium | `scrollback` refused for a guest context, so no `H` is staged. The program can still reprint — stated, not hidden |
| Grant outlives its usefulness | Medium | Absolute expiry, 1 hour default, 24 ceiling; dies with the session; `share revoke --all` |
| Guest keeps typing after permission is withdrawn | Medium | Watch clears `interactive`, `recompute_writer` promotes the owner, `writer_changed` fans out |
| Revoked guest reconnects in a loop | Low | Rejected Upgrade is a terminal state in the page, distinct from a transport retry |
| Guest token in a proxy log | High | Subprotocol only, never a query string; `#g=` read once and cleared; hours, not months |
| Grant leaks from the state dir | Medium | Only `sha256(token)` stored; `0600` in a `0700` dir |
| Third-party relay reads `D` / `env` | High | Funnel does not decrypt (vendor-documented); same-box proxy is user-owned; `cloudflared` labelled; no Fyolo relay exists |
| Funnel publishes the box's hostname | Low | Named. Unauthenticated Upgrades get silence; the static page carries no secret |
| Owner assumes `pair --rotate` revoked the guests | Medium | It does not. `pair --rotate` prints the live grant count; `share revoke --all` is the verb |
| A daemon without the guest gate honours a grant | High | Impossible by construction: one process reads and enforces, and a build without the gate refuses to mint |

Threat model in one sentence: **possession of a guest link is, for its lifetime, read access to one session — and if the owner enabled typing, a shell as the owner on that box.** The RFC's own sentence, narrowed to one session and given a clock.

---

## PR plan

Nothing starts before the web-client RFC's PR 1–4 are in. Each PR leaves `fyolod` useful if the next never lands.

| # | PR | What lands | Done when |
| --- | --- | --- | --- |
| 1 | **`AuthContext` seam** (the fourth thing) | `handle_conn` takes a stream generically plus an `AuthContext`; Unix, SSH, and owner-token WSS all pass `Owner`; no behaviour change | `stdio_bridge.rs`, `wss_bridge.rs`, `join_invariant.rs` green with no edits beyond the call signature |
| 2 | **Grants + the guest gate** | `guests/` directory, `fyolod share` / `list` / `revoke`, hash lookup in the accept path, `notify` watch, default-deny op match, `scrollback` refused, `max_attachments` | A guest attaches observe and nothing else: another session, `fs_read`, `git_diff`, `create`, `send` all answer `denied`; no `H` arrives; revoke closes the splice; an expired grant is refused at Upgrade |
| 3 | **Typing grants** | `may_type`, `interact` gated on it, live demotion when the flag clears | Guest claims the token and `writer_changed` reaches the owner; the owner's re-claim takes it back; clearing the flag demotes a live guest |
| 4 | **Guest chrome in the web client** | `#g=` bootstrap, no session list, Take input only when granted, two distinct end-states | A revoked grant shows the ended state and does not retry; a transport drop does |
| 5 | **The Mac sidebar** | Row menu item, sheet, one-time link display, guest badge, *Take Input Back*, *End Guest Access* | Minting from the sidebar produces a link that opens on another machine; the badge appears and clears; `review-copy` passes on every string |
| 6 | **Docs** | `DEPLOY.md` Funnel recipe with the admin-enablement note and the plaintext table; the landing docs page | A colleague with only a browser reaches a session on a clean VPS, and the doc says which legs saw plaintext |

Observe-only is a coherent stopping point after PR 2 + 4 + 5. PR 3 is separable and skippable.

---

## Risks

### The risk that does not design away

**A bearer link is not a person, and we have no accounts to make it one.** The daemon cannot distinguish the invited colleague from whoever they forwarded the link to, or from a bot that scraped it out of a Slack channel. `attached_clients` counts sockets; `Hello.client` is a string the client chose; the accept log records a peer address a phone changes at the door. So audit honestly reads **"how many attachments hold this grant, and from where"** — never "Alex".

That is not deferred work. It is the direct consequence of two commitments being kept: no accounts, and no crypto or PKI of our own. The mitigations narrow the window — one hour, one session, one-time display, observer default, attachment cap, instant revoke — and none of them close it. Anyone who wants identity-bound access already has the tool, and it is an SSH key.

The product consequence: **this feature is for people the owner already trusts**, and the copy must not imply otherwise. The moment the pitch becomes "share safely with anyone," the design is being oversold.

| # | Risk | Severity | Mitigation |
| --- | --- | --- | --- |
| 1 | A link is a bearer credential, not an identity | **High, accepted** | Above. The copy must not overclaim |
| 2 | A typing guest has the owner's machine | **High, accepted** | Off by default, named in the sheet, instant revoke and take-back, no sandbox |
| 3 | The `AuthContext` seam is estimated as "a token file" | Medium | It is called out as the fourth thing and lands as its own behaviour-neutral PR |
| 4 | Reachability depends on Funnel, which a tailnet admin may not enable | Medium | Documented; the operator's own proxy is the fallback; the UI refuses to hand out a URL that cannot open |
| 5 | ACL rots as the protocol grows | Medium | Default-deny catch-all; the guest arm is one reviewable list |
| 6 | Someone widens `attached_clients` from a count to a list | Medium | It is a `usize` the Mac already decodes; widening in place is a `proto:1` break |
| 7 | "Share" means two features | Low | Vocabulary fixed here; `review-copy` catches drift |
| 8 | A secret is already on screen when the guest joins | High, inherent | Only the owner can judge it. The sheet says the guest sees the current screen; the docs say invite into a worktree |
| 9 | An owner shares once and forgets | Medium | Absolute expiry with a 1-hour default is the whole answer. There is no "never expires" |
| 10 | This work is built assuming the companion wire survives | Medium | It must not be. The migration order is web → guest credential → phone-direct → delete `CompanionServer` + `WireProtocol` |

---

## Open questions for a human

The first gates everything else.

1. **Does live sharing ship at all?** Top-5 #2 asks whether live sharing with another *person* is a v2 goal or a non-goal, and calls it a product commitment rather than an engineering choice. This doc shows the delta is three items and one seam, and that no invariant has to bend. It does not argue that it should ship: the failure mode is someone else's shell on the user's machine, the reachability path is one we do not control, and the transcript share covers the common "show me what your agent did" ask with none of the risk. **The user's call.**
2. **If it ships, does typing ship with it?** Observe-only is smaller in every dimension — no handover UI, no demotion path, disclosure-only blast radius — and PR 3 extends it later without rework.
3. **Is `--wss-origin` an acceptable source of truth for the link's base URL?** It means guest sharing is off until the operator declares a public origin. The alternative is probing `tailscale status`, which adds a CLI dependency.
4. **Audit: off-wire (grant record + accept log) or one additive `SessionInfo` field?** This doc recommends off-wire, on the grounds that a per-attachment list promises identity a bearer token cannot deliver.
5. **How long may a grant live?** 1 hour default, 24 ceiling is the recommendation. "Until I close it" is a defensible different opinion.
6. **Verify Funnel's flag surface before the docs promise it.** TLS termination and the no-decrypt guarantee are vendor-documented and quoted above; the port list is 443 / 8443 / 10000. Unverified: `--set-path` behaviour under `funnel` specifically, and whether the admin toggle is per-node or per-tailnet in the current release.
7. **Does the phone-direct migration get scheduled off the back of this?** The payoff analysis says the blockers are discovery, per-device credentials, and two presentation-boundary violations — not the panes. That is a roadmap decision, not a design one.

Not in scope, named so nobody re-derives them: a workspace-level grant, guest access to the file or git planes, E2EE through an untrusted relay, and anything that reads as multiplayer typing.

---

## References

- [Fyolod web client on official Ghostty WASM](20260818-fyolod-web-client-ghostty-wasm.md) — the WSS binding, the pairing token, the Origin algorithm, observe/interact attach, `--web-root`, the renderer and theme rules the guest page inherits
- [fyolod Session Protocol](20260730-fyolod-session-protocol.md) — §C.5 writer policy, JOIN barrier, authoritative dims; §C.7 `denied`; §C.8 security-sensitive fields; §C.12 file plane; §C.13 `git:` resource; §F #3 sharing ACL; §F #4 relay-as-blind-pipe; §H #5 no CRDT; §H #8 no embedded crypto; §H #9 no second protocol for the phone; Top-5 #2 the sharing product call
- [Device architecture](20260805-fyolod-device-architecture.md) §2.1 — every UI is a client of the device that owns the session; the presentation boundary
- [Share an agent session (transcript link)](20260628-session-share.md) — the other "share": a rendered transcript on a server we would run, read-only, not this
- `fyolod/src/protocol.rs` — `Control::Hello { client }` (no `client_name`), `Attach { mode }`, `SessionInfo { attached_clients, writer_client_id }`, `Event::WriterChanged`, `ErrorCode::Denied`, `FsList` / `GitDiff` / `UploadOpen`
- `fyolod/src/session.rs` — `info()` (`attached_clients` is `clients.len()`), `ClientEntry` (no name, no attach time, no peer), `recompute_writer`, `emit_writer_changed`, `SCROLLBACK_STAGE_MAX_BYTES`
- `fyolod/src/daemon.rs` — `serve`, `handle_conn`, `run_attach`
- `Shared/Sources/FyoloShared/WireProtocol.swift` (747 lines) + `Sources/fyolo/Companion/CompanionServer.swift` (1,345) — the second protocol this work retires; op-by-op mapping above
- `Sources/fyolo/Sidebar/SidebarView.swift` — `SessionRow.menuItems`, the row menu this feature joins
- `Sources/fyolo/App/Models.swift` — `Session.fyolodRemoteHost`, `fyolodSessionName`
- [Tailscale Funnel](https://tailscale.com/kb/1223/funnel) — TLS terminated on the node, relay servers do not decrypt, ports 443 / 8443 / 10000
- [tmate](https://tmate.io) — read-only and read-write session URLs; vendor-run relay, self-hostable
- `VOICE.md` — the register for every string above; run `review-copy` before shipping any of them
