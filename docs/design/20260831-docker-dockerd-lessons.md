---
title: What ten years of docker/dockerd teach the fyolo/fyolod split
status: active
type: rfc
created: 2026-08-31
updated: 2026-09-09
related:
  - 20260730-fyolod-session-protocol.md
  - 20260819-unify-server-plane.md
  - 20260817-one-path-local-through-fyolod.md
  - 20260827-fyolod-lifecycle-reconcile.md
  - 20260827-remote-access-dev-tunnels-model.md
---

# What ten years of docker/dockerd teach the fyolo/fyolod split

> docker/dockerd is the longest-running client/daemon pair whose scars are
> public. This RFC mines those scars for changes to the fyolo/fyolod
> architecture, and settles the one question the pair answers outright:
> `fyolo` is the only command a person types; `fyolod` is a daemon name,
> like `dockerd`. Every claim here is written against the tree; the document
> survived two rounds of adversarial review, recorded in §9.

---

## 0. Why docker, and how to read the analogy

The shapes map almost one to one:

| docker | fyolo | state of the analogy |
| --- | --- | --- |
| `docker` CLI | `fyolo` (today: `scripts/fyolo`, 779-line shell) | this RFC, §1 |
| `dockerd` | `fyolod` | holds |
| `docker.sock` | app control socket + fyolod Unix socket | §5 |
| Engine API version negotiation | `hello` `proto`/`min_proto` (§C.3) | mechanism shipped; the policy and tests around it are not, §2 |
| Engine API support window | none stated | §2 |
| `docker system dial-stdio` | `fyolod stdio` | already identical |
| `docker context` | `~/.ssh/config` alias | ours is simpler; keep it |
| containerd/runc extraction | the accretion risk on fyolod | §6 |
| rootless mode (year ten) | systemd `--user` (day one) | already avoided |

Four of their lessons we already banked without paying for them. This
document exists partly to say so, so nobody re-argues them:

1. An API over an exec'd stdio pipe is the right remote transport.
   `docker -H ssh://` literally runs `docker system dial-stdio` on the far
   end. `fyolod stdio` is the same mechanism, validated by ten production
   years. (§H #3 stands: the pipe is OpenSSH's, never ours.)
2. A root daemon is a decade-long regret. docker shipped rootless in year
   ten. fyolod was born user-scoped. No work here; just don't regress.
3. A named-endpoint registry is overhead when ssh aliases exist.
   `docker context` reinvents `~/.ssh/config` because docker predates
   caring about it. We read the ssh config as authoritative (§A) and need
   no second registry.
4. Version-range negotiation is already in the handshake (§C.3 and
   `protocol.rs`). What remains of it is policy, not mechanism — §2.

The rest of the document covers the places where the analogy still demands
work. Each section ends with the change it proposes.

---

## 1. The decision this RFC records: one command, two binaries

Nomad's answer (one binary, `nomad agent` mode) fits products where the
daemon is the product on every node. fyolo's brain on a Mac is the app,
and the CLI has a verb class (`open` via LaunchServices, `notify`,
`focus`) that only means anything where the app lives. docker's answer
fits us: `fyolo` is everything a person or an agent types on a machine
that has the client; `fyolod` is the daemon and the machine-invoked
plumbing. `systemctl status` shows a thing named like `sshd`, because it
is a thing like `sshd`.

This is a naming and packaging decision, not a merge. The server-plane
RFC's §7.8 rejection of a single binary stands and is not re-proposed
here: a daemon named `fyolo` would land on the support-copy path every
installed hook names absolutely, and a router named `fyolo` cannot
dispatch to a binary with its own name. Two binaries, two names.

### 1.1 The surface being migrated, in full

The migration has to start from the whole person-facing surface, not one
namespace. What people can type today:

- `scripts/fyolo` (the shell client): `open`, `sessions
  list/watch/spawn/run/send/read/close/focus`, `agent report`, `notify`.
  `agent report` is not purely app-plane: with `FYOLOD_SESSION_ID` set it
  execs `fyolod set-status` (`scripts/fyolo:670-687`), so it already
  straddles both planes.
- `fyolod`, top level: `logs`, `serve`, `pair`, `handoff`, `create`,
  `list`, `kill`, `send`, `set-status`, `agent` (`install`/`uninstall`),
  `attach`, `watch`, `stdio`, `status`, `stop`, `deploy`, `service`, plus
  `--host` variants of `deploy`/`list`/`attach` that duplicate the
  `remote` namespace (`main.rs:53-349`).
- `fyolod remote`: `deploy`, `list`, `attach`, `open`.

Every row above needs a destination, not just the `remote` namespace. The
map this RFC proposes:

| today | destination | notes |
| --- | --- | --- |
| `fyolo sessions …`, `open`, `notify`, `agent report` | stays `fyolo` | contract frozen; see §4 for which socket serves it when |
| `fyolod remote …` and top-level `--host` twins | `fyolo remote …`, one spelling | the duplicate top-level forms retire with a deprecation notice, not silently |
| `fyolod create/list/kill/send/attach/watch/status/logs` | `fyolo …` everywhere — boxes get the client too (§1.2, amended 2026-09-09); the `fyolod` spellings keep working | see §1.2 |
| `fyolod pair/serve/service/deploy` | stays `fyolod` | operator plumbing for the box itself |
| `fyolod stop` | stays `fyolod`, on-box only | stops the daemon under it; destructive enough that it should require being on the box, like `systemctl stop` |
| `fyolod handoff`, `fyolod stdio`, `fyolod set-status` | stays `fyolod`, frozen | machine-invoked: the upgrade path, the SSH exec target (its name is in the wire path), and the hook target (hooks exec it by absolute path) |
| `fyolod agent install/uninstall` | stays `fyolod` | host integration, written by the deploy loop; a person runs it only to repair a box |

### 1.2 Where each command exists

Amended 2026-09-09; the original scoping and the evidence against it are
recorded in §9. Tracked as issue #628.

The client ships everywhere the daemon does. The reconcile loop installs
`fyolo` beside `fyolod` in the same pass, with the same
copy-beside-rename-over discipline, so a box's client and daemon are the
same build and skew between them is structurally impossible — §3's
lesson satisfied for free on boxes. The cost is roughly double the
copied payload per deploy; the alternative — a person typing `fyolo`
into a box session and reading `command not found` — was priced by
watching it happen.

PATH is the daemon's problem, not the dotfiles'. fyolod already injects
`FYOLOD_SESSION_ID` into the sessions it spawns; it additionally
prepends its own binary's directory to those sessions' PATH. Every
terminal opened through fyolo finds `fyolo` with zero host mutation —
the same principle as never overriding `~/.ssh/config`. A bare SSH login
outside fyolo keeps whatever the box's `~/.profile` does; that is not
our session, and DEPLOY.md keeps teaching the full
`~/.local/bin/fyolod` path for repairs made over plain SSH.

On a box, `fyolo` speaks the framed protocol to the local daemon
socket — §4's single-API policy applied to our own client. Session verbs
(`sessions …`, `version`, `agent report`) route to the local channel;
`agent report` already straddles, exec'ing `fyolod set-status` when
`FYOLOD_SESSION_ID` is present. App-plane verbs (`open`, `notify`,
`focus`) have no daemon meaning and fail with one line naming the
reason — no app on this host — rather than pretending.

Hooks are untouched: they keep exec'ing `fyolod` by absolute path, the
frozen machine contract in §1.1. `fyolod pair/serve/handoff/stop` stay
daemon-spelled operator plumbing, exactly like `dockerd`. The curl
installer stays deferred (§7): the Mac's reconcile loop reaches every
box the user has, so no second install path exists and the single-writer
invariant holds.

### 1.3 Mechanics, costed honestly

A second `[[bin]]` entry is not enough: the crate's modules are declared
from the binary crate root (`main.rs`), so a second bin cannot import
them. The real shape is a lib extraction (`src/lib.rs` declaring the
module tree, two thin `src/bin/` entries) — mechanical, but a refactor
with a diff, not a one-line change.

Channel binding: today `build-app.sh` rewrites three variables at the top
of the shell script so `fyolo-dev` drives the dev app
(`scripts/build-app.sh:188-198`). The Rust client selects the channel
from argv[0] instead: the dev bundle installs the same binary under the
name `fyolo-dev`, which selects the `.dev` bundle id, `~/.fyolo-dev`,
and the dev socket. Two paths must be pinned down before this ships,
because installed hooks name the support-copy path absolutely and end
`2>/dev/null || true`, so a path mistake fails silently: the release
app's support copy keeps the exact path `CommandLineTool.supportCopyURL`
owns today, and the dev app keeps its own. The port lands behind the
existing paths or it does not land.

### 1.4 Migration order

1. P1, verb collection in shell: `scripts/fyolo` gains `remote …` by
   exec'ing the bundled `fyolod`, and the Mac-side docs stop teaching
   `fyolod` as a typed command. One prerequisite the script lacks
   today: a bundled-daemon locator. Its only daemon lookup is `agent
   report`'s `FYOLOD_BIN`, then `~/.local/bin/fyolod`, then `PATH`
   (`scripts/fyolo:670-677`), which on a machine with both channels can
   select a daemon from a different bundle than the app the script
   drives. P1 adds one helper that resolves the daemon inside the same
   bundle the script's channel bindings point at, with `FYOLOD_BIN`
   kept as the explicit override, and `remote …` and `agent report` both
   use it. With that, shippable now; touches no session backend.
2. P2, the Rust `fyolo` client. **Scheduled by the server-plane RFC, not
   by this one.** Unify-server-plane Stage 10 moves the CLI verb by verb
   once there is one session backend to route to, precisely so no verb is
   ported twice; this RFC adds to that stage the lib extraction, the
   argv[0] channel selection, and the two frozen contracts (`agent
   report` byte-compatible; `sessions … --json` value-compatible), and
   removes nothing from its gates. Until Stage 10, the shell script stays
   the router.
3. P3: the script becomes a one-line exec shim on its frozen path (hooks
   reference it absolutely), then disappears when nothing does.

---

## 2. Lesson: a support window is policy, and policy is the hard part

Range negotiation is already in the handshake: the client's `hello`
carries `proto` and `min_proto`, the session runs at the highest common
version, and no overlap returns `hello_err {code:"incompatible",
supported:[…]}` with immediate close (§C.3; `protocol.rs`
`Control::Hello`/`HelloErr`). §C.3 also already commits the
compatibility matrix (old client × new host and the reverse, at the
intersection, for all of proto:1) and names the test shape (golden-file
codec tests plus replayed skew transcripts).

One implementation/document gap to record: §C.3 says host and client
*each* advertise `[min_proto, proto]`, but the implemented `hello_ok`
carries only the chosen `proto`, with no host minimum
(`protocol.rs:528-550`), and the daemon today accepts protocol 1 only.
The gap hasn't bitten because there is one protocol version to choose
from; before there are two, either `hello_ok` grows the host's range or
§C.3 is amended to define `hello_ok.proto` as the negotiated result and
nothing more. Pinning that down belongs with the window work below.

What docker actually has and we do not is everything around the
mechanism:

- **A stated support window.** §C.3 commits proto:1 additivity but says
  nothing about how long a payload encoding lives. The payload version
  bytes (snapshot v3 packed / v2 VT, history v2, grid v2) hard-refuse
  unknown versions, and §C.3 marks snapshot encoding "deliberately
  unstable until v1." That instability window has to close: the policy
  this RFC proposes is that once v1 ships, a new payload version within a
  supported protocol version ships beside its predecessor for one
  release window, and a removal (like snapshot v1's) must write down its
  justification. This amends §C.3's payload-encoding policy; it does not
  discover a missing mechanism.
- **The tests §C.3 promises.** "POC smoke tests grow into this" is a
  roadmap line, not a suite. The skew matrix needs to actually run in CI
  before the next payload change, because iOS is the client that cannot
  be re-shipped in a day: App Store review means the phone and the Mac
  never update atomically, and so far every protocol change has won the
  ordering gamble by shipping the Mac first. That is a habit, not a
  mechanism.
- **An error that names both sides.** `hello_err` carries the host's
  `supported` list only. A client rendering "phone speaks 3..4, host
  speaks 5" needs its own range in the message it shows; today it must
  reconstruct half the sentence. Small, additive, worth doing with the
  test work.

The reconcile loop keeps skew transient for daemons the Mac owns, and
that has quietly served as the entire policy. Unowned daemons (a
pre-baked devbox image, any future non-reconcile install path) and the
App Store cadence are the two populations it does not cover; the window
plus the tests are what covers them.

---

## 3. Lesson: make skew visible before making it survivable

`docker version` prints client and server versions in one output. It is
the first line of every docker bug report and the cheapest support tool
they built.

Most of the data already exists: `hello_ok` returns the daemon's build
(`version: <app version>+<build>`) exactly so "fyolod 0.43 on ukvps;
this app needs 0.44" can be said, and `fyolod status --json` already
reports local binary and daemon state. But the Mac's device registry
keeps less than the handshake learns: `FyolodDevice` persists `id`,
`daemonVersion`, and routes, and the handshake path drops `proto` on the
floor (`FyolodDevice.swift:62-80`, `FyolodClient.swift:615-634`). The
remote rows are the Mac client's last-handshake observations, not daemon
history, and today they contain no protocol number.

So the change is presentation plus one small persistence fix, still no
new probe: the device registry also records the negotiated `proto` and
the observation time at each handshake, and `fyolo version` wraps
`fyolod status` for the local rows and that registry for the remote
ones, printing one table:

```
fyolo        0.34.0+912          (client, dev channel)
fyolo.app    0.34.0+912          (running)
fyolod local 0.34.0+912          proto 1
ukvps         0.34.0+907          proto 1   ← behind, reconciles on next deploy
```

A host it has never spoken to is absent, not probed. Every remote row is
stamped from its observation time ("as of last connect, 2h ago"), so a
stale row announces its staleness instead of posing as live state. No
new transport calls, no parallel version registry. Ship it before the §2
policy work: seeing skew is cheaper than surviving it, and tells us
which windows matter.

---

## 4. Lesson: one API, or no ecosystem

docker's CLI is replaceable because the Engine API is the product.
Compose, Portainer, and every CI plugin speak the socket, and none of
them asked docker's permission. There was never a second, easier API to
grow on.

Our exposure: we have two client-visible surfaces, the framed session
protocol (documented, versioned, transport-agnostic) and the Mac app's
control socket (JSON, shell-script consumer, shaped by app internals).
The unify-server-plane RFC already sentences the app socket to
absorption. The docker lesson is about the meantime: third parties build
on whatever surface the examples use.

The policy, with its exceptions named so review can enforce it:

- The framed protocol is the only surface third-party tools may target,
  and the only one the docs teach for programmatic use.
- Two public contracts are temporarily served by the app socket and are
  value-frozen while they migrate: `fyolo agent report` (already
  straddling: it execs `fyolod set-status` when a daemon session id is
  present) and `fyolo sessions … --json` (agents script against it).
  Their migration to protocol verbs is Stage 10's existing work; the
  freeze is on observable values, per Stage 10's own gate.
- Permanently app-plane, by design: `open`, `notify`, `focus` (§4.1 of
  the server-plane RFC keeps them in Swift). These are not exceptions to
  the API policy; they are UI verbs with no daemon meaning.
- Everything else new lands on the framed protocol. A verb that could go
  either way goes to the daemon, because every verb ported later is
  migration debt. A new app-socket command outside the lists above is
  the thing review rejects.

---

## 5. Lesson: decide what the socket is worth before the ecosystem does

docker.sock reachable = root. Everyone knows; nobody can fix it; a decade
of tooling depends on the socket being all-powerful, so scoping it now
would break the world. It is the canonical case of a security boundary
defined by accident and frozen by adoption.

The lesson lands in two halves: state the current model honestly before
tools shape themselves around an undocumented one (§5.1, prose only),
and price the scoped tier as the protocol-and-daemon work it actually is
(§5.2, deferred until someone needs it).

### 5.1 What is true today, and should be written down as a promise

- The Unix socket is full authority, by design: anything that can open it
  can inject keystrokes into any session, which is user-equivalent code
  execution. That is the point (`fyolo sessions send` driving sibling
  agents is a feature), and AF_UNIX plus filesystem permissions is the
  right fence for same-user-same-box (§A: the OS is the security team).
  No per-verb ACL on the socket will ever be added; a caller you don't
  trust with your shell must not reach the socket at all.
- The pairing token is currently daemon-equivalent too. `serve --wss` is
  a TCP listener that refuses non-loopback binds, carries the same framed
  protocol onto the daemon socket, and DEPLOY.md already says it plainly:
  whoever holds the token has full access to the daemon until it is
  rotated. The invariants worth stating are therefore **no non-loopback
  bind** (the flag parses the address and refuses otherwise) and **no
  embedded TLS** (§H #3; TLS belongs to the tunnel in front) — not "no
  TCP listener," which the tree already contradicts.

Writing 5.1 into the protocol doc is the prose-only work, and its value
is docker's negative example: the promise must exist before third-party
tools shape themselves around an undocumented "the token can do
everything."

### 5.2 The scoped tier, if and when a phone deserves less than everything

A token tier that grants only session planes (attach, input, files
within advertised roots, upload) and can never reach `deploy`,
`service`, or hook installation would need: token claims in the pairing
payload, an authorization check on every control op in the daemon,
enforcement on every transport that reaches the socket, and a closed
catalog in the protocol doc where new privileged verbs are
loopback-invisible until argued in. That is protocol and daemon work
with tests, not a documentation pass. It becomes worth scheduling when a
token holder exists who should not be daemon-equivalent: in practice,
when device pairing extends beyond the owner's own phone. Until then,
5.1's honest statement is the security model.

---

## 6. Lesson: the daemon that survives is the boring one

dockerd accreted build, swarm, networking, and plugins, until the
industry extracted the part it actually needed (containerd/runc) behind a
narrow interface and Kubernetes dropped dockerd entirely. The daemon was
punished for being interesting.

fyolod will face a steady stream of "the daemon should also…" proposals,
and some are even right: the deciding rule from the device architecture
(§4.1: would two people on two machines expect the same answer?) has
already, correctly, moved git reads and agent integration server-side. So
the docker lesson here cannot be "keep the daemon tiny"; that would
contradict §4.1. The lesson is to keep the runtime core extractable:

- The PTY host, session lifecycle, and framed protocol core is the
  containerd of this system. It must never import from the planes. git,
  files, upload, and agents may depend on the core; the core compiles
  without them. Today this is a module-dependency discipline; if it ever
  needs teeth, it becomes an internal crate boundary (`fyolod-core`),
  the same move as `fyolod-vt`. The §1.3 lib extraction is the natural
  moment to draw the line, since the module tree is being restated
  anyway.
- Every plane admission answers both tests, in order: first §4.1 (does it
  belong server-side at all?), then bytes versus judgment. The daemon
  moves and reports bytes (a diff, a file, a status string); rendering,
  ranking, and interpretation stay in clients. A plane that wants the
  daemon to have opinions is how dockerd got swarm.
- `HOST_CAPABILITIES` names what accreted, but it mixes plane names
  (`git`, `files`, `upload`) with feature flags of the core
  (`send_wait`, `grid_diff`, `handoff`). If the list is to serve as the
  extraction seam, that distinction gets written down when the core
  boundary is drawn; until then it is a capability list, not a map.

---

## 7. What we are explicitly not copying

- `docker context`: ssh aliases are our contexts. No registry.
- Plugin binary discovery (`docker-buildx` on `$PATH`): an extension
  story is premature until the framed protocol has third-party consumers.
  Revisit when one exists.
- A curl installer: separate discussion, gated on a topology (phone to
  box without a Mac) that doesn't exist yet. When it comes, the script
  fetches a binary and execs `fyolod service install`, so the reconcile
  loop stays the single writer. (§1.2's client-on-a-box question no
  longer waits on it — the 2026-09-09 amendment ships the client through
  the reconcile loop.)
- A single merged binary: rejected in server-plane §7.8 for path and
  dispatch reasons that this RFC's two-binary shape avoids. Not
  re-proposed.
- An HTTP shape for the API: the framed protocol fits PTYs in a way
  request/response does not. docker's REST shape is an artifact of 2013.

---

## 8. Order of work

Rebased on unify-server-plane's stage order; this RFC schedules nothing
ahead of a stage that RFC already gates.

| # | Change | Cost | When |
| --- | --- | --- | --- |
| 1 | `fyolo version`: persist `proto` + observation time in the device registry, wrap `fyolod status` + registry rows (§3) | small | **shipped, PR #543** |
| 2 | P1 verb collection: bundled-daemon locator, `fyolo remote …` in the script; Mac-side docs stop teaching `fyolod`; deprecation notice on the top-level `--host` twins (§1.1, §1.4) | one to two days | **shipped, PR #543** |
| 3 | §5.1 written into the protocol doc as the stated security model | prose only | **shipped, PR #543** |
| 4 | §2 policy: payload support window amending §C.3, the skew test matrix in CI, both-ranges error, `hello_ok` range gap resolved | tests + small protocol additions | before the next payload-format change |
| 5 | Core-vs-planes import discipline (§6) + single-API policy with its named exceptions (§4) | review discipline | standing, from now |
| 6 | P2 Rust `fyolo` client: lib extraction, argv[0] channels, frozen contracts (§1.3) | the real port | **started 2026-08-31** — Stage 10 pulled forward after the one-backend gate was met early (unify-server-plane, restamp of that date); its gates unchanged |
| 7 | §5.2 scoped token tier | protocol + daemon + tests | when a non-owner token holder exists; not scheduled |
| 8 | §1.2 amendment: client in the deploy payload + reconcile verification, daemon-injected PATH for spawned sessions, box-side routing to the local channel, DEPLOY.md flip | deploy + dispatcher; the routing rides Stage 10's verb ladder | issue #628 |

---

## 9. Review record

This document went through two rounds of adversarial (codex) review; the
body above is the corrected result. The record stays here so the failure
modes it caught are not re-argued and not repeated.

**Round 1 — request changes.** The first draft failed its own
against-the-tree standard in four places, each now fixed in the body:

- It proposed adding version-range negotiation that already existed:
  `Control::Hello` carries `proto`/`min_proto`, and §C.3 already
  specifies highest-common selection and the incompatible error. The
  real gap is policy, tests, and error shape (§2).
- It declared "No TCP listener, ever" and described the pairing token as
  a bounded session-plane credential. Both were false: `serve --wss` is
  a shipped loopback-only TCP listener, and DEPLOY.md documents the
  token as full daemon access. §5 now states the true invariants
  (loopback-only bind, no embedded TLS) and prices scoped tokens as real
  protocol/daemon work.
- It scheduled the Rust CLI port ahead of unify-server-plane Stage 10,
  which deliberately gates the CLI move on having one session backend so
  no verb is ported twice. §1.4 and §8 now defer to that stage.
- It called a second `[[bin]]` cheap; the modules are declared from the
  binary crate root, so the real cost is a lib extraction (§1.3). It
  also treated `fyolod remote …` as the whole person-facing surface and
  assumed `fyolo` exists on the VPS; §1.1 now inventories every
  top-level verb and §1.2 separates Mac-side from on-box documentation.

**Round 2 — three residual defects, all fixed in the body:**

- The "full" verb inventory still omitted `serve`, `handoff`, `stop`,
  `set-status`, and `agent install/uninstall` — exactly the commands
  whose deprecation story is most delicate (the upgrade path, the hook
  target, host integration). §1.1's table now maps each one.
- The prose claimed both sides of the handshake advertise ranges; the
  implemented `hello_ok` carries only the chosen `proto`
  (`protocol.rs:528-550`), and the daemon accepts protocol 1 only. §2
  now records this as an implementation/document gap to resolve with the
  window work.
- The `fyolo version` design claimed remote rows come from stored
  `hello_ok` results, but `FyolodDevice` persists no protocol number
  and the handshake path drops `proto` (`FyolodClient.swift:615-634`).
  §3 now includes the persistence fix and stamps every remote row with
  its observation time.

Round 2 also confirmed P1 is not shippable without a bundled-daemon
locator (the script's only daemon lookup can select a different
channel's daemon); §1.4 makes the locator P1's first deliverable.

**Amendment 2026-09-09 — §1.2 reversed on the box client.** The original
§1.2 deferred "client on a Linux box" to the curl-installer topology
(§7). The deferral did not survive contact with use: the
box-with-an-agent topology already exists, and a person typed `fyolo`
into a VPS session — the Mac-side docs and skills train exactly that
muscle memory — and read `command not found`. §1.2 now ships the client
through the reconcile loop with daemon-injected PATH for spawned
sessions, §7's installer bullet no longer gates it, and §8 row 8 tracks
the work as issue #628.
