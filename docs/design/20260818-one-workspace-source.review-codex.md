---
title: "Adversarial review: One workspace source — the inspector reads the session's device"
status: archived
type: rfc
created: 2026-08-18
updated: 2026-08-31
---

# Adversarial review: One workspace source — the inspector reads the session's device

## Verdict

> Request changes. The RFC identifies a real wrong-filesystem bug, but its source
> type preserves local as a special backend, its workspace owner is unresolved,
> and its staging overstates what can ship without protocol work.

Do not approve the RFC as written. Stage 0 should ship as a narrow correctness
fix: a session on another device must never fall through to this Mac's project
path. The rest needs another design pass.

The proposed `WorkspaceSource` is the wrong final abstraction. A device case
keyed by SSH alias mistakes a route for identity, while a separate `.local`
case makes this Mac special after the accepted architecture says it is just
another device. The durable object is a workspace reference: a device identity
plus a canonical root. A session points to that reference; a `.host` container
does not own it.

The staging also fails its own “no protocol change” claim. The existing upload
plane can land verified bytes atomically, but it cannot detect that an agent
changed the destination after the editor read it, and the read/list replies do
not carry the mode that Stage 3 promises to preserve. A correct save therefore
needs an additive precondition and file metadata on the wire. Separately, a
session created by another client does not report a workspace reference, so the
viewer cannot derive one from the session without extending the roster shape.

## Source citation audit

### Incorrect or stale citations

| RFC citation | What is actually there | Finding |
| --- | --- | --- |
| `FyoloStore.swift:421` for the plain-SSH guard | Line 421 is `if project.kind == .host { return nil }`. The plain-SSH guard is line 422: `guard session(id)?.sshHost == nil else { return nil }`. | Wrong line and wrong branch. |
| `FyoloStore.swift:420` for the `.host` guard | Line 420 is `guard let id = selectedSessionID, let project = project(for: id) else { return nil }`. The `.host` guard is line 421. | Wrong line. The two table rows have their citations swapped by one line. |
| `FileBrowserView.swift:216-250` for the words “Remote session” | Lines 216, 231, and 249 are the three `if sshHost != nil` gates. The actual title is at line 297: `localized("Remote session")`. | The range proves the gates, not the quoted UI result. |
| `UploadCommit` at `:555` after `daemon.rs:1497-1499` | The nearest filename makes this `daemon.rs:555`, which is `let writer = tokio::spawn(write_outbound(wr, out_rx, backlog.clone()));`. `UploadCommit` is `fyolod/src/protocol.rs:555`. | Ambiguous shorthand resolves to the wrong file. Use the filename again after changing files. |

### Verified citations

| RFC citation | Verification |
| --- | --- |
| `FyoloStore+Fyolod.swift:534-538` | Correct. A remote session opened from a project is appended to that local `Project` and selected. |
| `FileBrowserView.swift:53-54` | Correct. The pane derives its remote branch from `session.sshHost` only. |
| `DeviceContext.swift:154`, `:218` | Correct. Both sites use `session.fyolodRemoteHost ?? session.sshHost`. |
| `20260817-one-path-local-through-fyolod.md:116-124` | Correct. It records the local/SFTP/dead split and the fyolod fall-through. Its own `FyoloStore.swift:416-422` citation is broad enough to include the current guards. |
| `20260817-one-path-local-through-fyolod.md:73-79`, `:1236-1260` | Correct. Plain SSH stays terminal-only, SFTP retires, and the Stage 7 gate is zero `SFTP` references. |
| `20260817-one-path-local-through-fyolod.md:70-77` | Correct. The settled pane result is to name the missing daemon and offer installation. |
| `SFTPClient.swift:52-53`, `:22-38` | Correct. The only open flag is `SSH_FXF_READ`, and the packet table has no write, rename, create-directory, or remove operations. |
| `FileBrowserView.swift:68`, `:216`, `:231`, `:249` | Correct. These are the SFTP tree, Search, Changes, and Issues gates. |
| `protocol.rs:457`, `:473`, `:485`, `:499`, `:516`, `:535`, `:548`, `:555` | Correct. They are `SubscribeResource`, `FsList`, `FsRead`, `UploadOpen`, `FsSearch`, `GitDiff`, `FsMatch`, and `UploadCommit`. The repeated citations in §5 point to the same definitions. |
| `daemon.rs:1504` | Correct in shape. It introduces `F` chunking. The payload is 65,519 bytes, not a full 64 KiB, because `daemon.rs:1508` subtracts the 17-byte file header from the 64 KiB frame cap. |
| `FyolodClient.swift:29-31` | Correct for the attach channel declining `resources`, `fs_watch`, and `files`. The explicit “own channel” design is at lines 35-37, just outside the citation. |
| `daemon.rs:1497-1499` | Correct but loose. The workspace-root error ends at line 1497; the `resolve_project_dest` call is line 1499. |
| `files.rs:709-743` | Correct. Commit checks size, checks the new-content sha256, syncs, sets permissions, and renames the dotfile. It does not check the old destination version. |
| `20260817-one-path-local-through-fyolod.md:1260` | Correct. It is the zero-SFTP gate. |
| `SFTPClient.swift:20` | Correct. `concurrentReads` is 8. |
| `FyoloStore+ProjectActions.swift:422-440` | Correct. `hostContainer` creates one alias-keyed `.host` block and gives it the first non-`~` root. |
| `Models.swift:328` | Correct. This is `Session.fyolodRemoteCwd`. |

The unnumbered source assertions add two corrections and three confirmations:

- The line counts are current: `SSHFileSystemProvider.swift` is 531 lines and
  `SFTPClient.swift` is 878.
- `fyolod/src/git.rs` does contain only status and diff behavior. That claim is
  accurate.
- `Shared/Sources/FyoloShared/WireProtocol.swift` does not embody the Rust/Swift
  fyolod agreement. It is the companion Mac/iOS protocol. The hand-written
  fyolod mirror is in `FyolodClient.swift`, whose control decoder currently
  knows upload replies but no `fs.list`, `fs.read`, resource, or git reply.
- `fyolod/src/resource.rs` does not assume one subscriber. Each resource keeps
  a `HashMap<ClientId, Sender>`, canonical roots share one watcher, and every
  subscriber receives the same published batch
  (`fyolod/src/resource.rs:124-168,239-327`).
- `crates/remote/src/protocol.rs` is not in this repository, so the Zed framing
  statement cannot be verified from the cited path here.

## The source type preserves the fork

The RFC's rule that panes stop reading session transport fields is correct. The
enum chosen to enforce it is not:

```swift
enum WorkspaceSource {
    case local(root: String)
    case device(alias: String, root: String)
}
```

It recreates the same split in two ways.

First, `alias` is a route, not a device. The accepted architecture makes
`host_id` the identity and `~/.ssh/config` the route authority
(`20260805-fyolod-device-architecture.md:85-104`). A workspace
keyed by alias forks when the same box is reached through LAN, WAN, and
Tailscale names. `DeviceContext` already prefers `deviceID` when both ends know
it (`Sources/fyolo/FyoloStore/DeviceContext.swift:214-225`); the new source
must not regress to the bootstrap identity.

Second, `.local` permanently names a direct-`FileManager` backend. The accepted
target says the Mac is one device, local and VPS sessions differ only in
`FyolodRoute`, and the inspector reads the workspace's device
(`docs/design/20260817-one-path-local-through-fyolod.md:224-237`). Keeping local as a
public source variant makes every workspace consumer preserve the branch that
the one-path RFC exists to delete.

Use one domain value:

```swift
struct WorkspaceReference: Hashable {
    let deviceID: String
    let root: String
}
```

Route resolution belongs below that value. A workspace client opens the local
socket or an SSH route for the referenced device, then exposes the same list,
read, subscribe, search, git, and save operations. A temporary direct-local
adapter may be useful while the one-path migration is incomplete, but it should
be an implementation detail with a deletion gate, not a lasting case every pane
can switch over.

The file identity must carry the source too. `openFileURL`, `GitDiffRequest`,
`IssuesPanelModel.repoRoot`, and the inspector's saved layout all store local
paths or file URLs today. A root-level enum does not stop a remote file from
losing its device when it moves into the editor overlay or survives a session
switch. The pane needs a value such as `(workspace reference, relative path)`,
not a staged local URL that later guesses where to save.

## The workspace belongs to neither `.host` nor the session

Open question 1 is already answered by the architecture. A workspace is a
canonical directory root on a device. It is a scope for files, git, and watch
state, distinct from a process container and distinct from a session
(`20260730-fyolod-session-protocol.md:126-142`). The device design
then makes it first-class and enumerable, with identity `(device, path)`
(`20260805-fyolod-device-architecture.md:164-188`).

Of the two choices offered by the RFC, derive the selected workspace from the
session, never from `.host`. That describes association, not ownership: the
session should carry a workspace reference.

The `.host` container is provably unable to own the root. `hostContainer` keeps
one block per alias and lets the first real directory replace `~`
(`Sources/fyolo/FyoloStore/FyoloStore+ProjectActions.swift:414-439`). Two
sessions on one device in `/srv/api` and `/srv/web` therefore share one
container root. Whichever arrived first wins for both. A linked worktree is a
third distinct root on the same device.

`Session.fyolodRemoteCwd` is a better migration input, but it is not the final
workspace identity. It is the process's spawn directory
(`Sources/fyolo/App/Models.swift:323-328`), and `SessionInfo.cwd` never follows
a later `cd`. More importantly, the daemon already stores
`WorkstreamSpec.project` and `.worktree` but drops both when it builds
`SessionInfo`; the roster exposes only `agent_id`
(`fyolod/src/session.rs:321-339`). A session adopted from another client cannot
tell this viewer which workspace owns it.

The migration rule should be explicit:

1. A session with a workspace reference uses it.
2. A remote session filed under a local project uses that project's
   device-keyed `remoteCheckouts` entry while old state is migrated.
3. A legacy `.host` session may use `fyolodRemoteCwd` as a provisional root.
4. The `.host` container path is never authoritative.
5. A daemon-created or phone-created session must receive its workspace
   reference from the device roster. Adding that field is a protocol change.

This also resolves remote worktrees. Each worktree is a separate workspace root
on the same device. The current `remoteCheckouts: [deviceID: path]` stores only
one checkout per project and device (`Sources/fyolo/App/Models.swift:113-128`),
so it cannot represent a base checkout and two remote worktrees. The workspace
registry already scheduled by the device architecture must own enumeration and
creation before remote worktrees can behave like local ones
(`20260805-fyolod-device-architecture.md:551-556`).

## The staging is not independently shippable as written

| Stage | Verdict | Required correction or dependency |
| --- | --- | --- |
| 0 — unify the branch | Shippable after correction | Four visible gates are not the whole local path. The view still gives `projectPath` to the drop target, local watcher, root refresh, and git badge (`FileBrowserView.swift:109-147,343-395`). A device source must cut off every local read, watch, mutation, and badge refresh. |
| 1 — `fs.list` + `fs.read` | Can ship as a static read-only tree after Stage 0 | The Swift client has no operation or reply types for either verb, no `F` assembler, and no workspace file identity. Opening another per-pane SSH pipe avoids a schema change but violates the accepted durable-connection design. Use the device connection object first. |
| 2 — subscribe `fs:` | Not shippable with Stage 1's channel as specified | Stage 1 negotiates `files`; subscription requires `resources`, and the protocol says the `fs:` kind also requires `fs_watch`. Capabilities are fixed at `hello`, so the channel must negotiate all three or reopen. The current daemon checks `resources` but never enforces `fs_watch` (`fyolod/src/daemon.rs:886-937`), which is itself a protocol implementation gap. |
| 3 — save through upload | Not safe without protocol work | Atomic landing prevents torn files. It does not prevent lost updates, and the client cannot preserve mode from the current read/list replies. The editor also accepts a local `URL` and performs synchronous local writes, so upload is not a drop-in provider swap. |
| 4 — missing verbs | Requires protocol change by definition | Stage 1 must hide or disable New File, New Folder, Rename, Delete, and drop gestures until these verbs exist. Reusing the local tree unchanged would expose actions backed by this Mac's `FileManager`. |
| 5 — delete SFTP | Does not depend on Stages 2-4 for SFTP parity | SFTP is read-only. A static `fs.list`/`fs.read` tree plus the settled plain-SSH install affordance can replace it. Live watch, editor save, and mutations are product gates, not dependencies inherited from SFTP. State that policy instead of presenting a strict dependency chain. |

There is a larger prerequisite. The accepted migration orders connection
ownership before panel work: one `FyolodConnection` per device owns health and
reconnect, and resource subscriptions recover through it
(`docs/design/20260817-one-path-local-through-fyolod.md:1075-1107`). The current helper is
explicitly one-shot: `withControlChannel` opens a transport, runs a closure, and
closes it (`Sources/fyolo/Terminal/Fyolod/FyolodClient.swift:1025-1042`). A
file pane can hold another transport open, but that rebuilds per-pane connection
ownership at the workspace layer.

If the implementation instead follows the device architecture's single pipe
with multiplexed channels, that work has an explicit additive protocol bump
because `hello` fixes one role per connection today
(`20260805-fyolod-device-architecture.md:395-404`). The RFC must say
which prerequisite it relies on. “New channel, no protocol change” cannot mean
both “another SSH stdio process” and “a channel on the durable device
connection.”

Stage 2's sleep gate is also false without a time bound. A watcher outlives its
last subscriber for 300 seconds, then retires
(`fyolod/src/resource.rs:47-54,174-197,440-470`). After a longer sleep the old
cursor is ahead of a new watch at sequence zero, so `gap: true` correctly forces
a full rescan. The gate should require exact replay inside the linger window and
a correct full rescan after it, not promise incremental catch-up after an
arbitrary sleep.

## Stage 3 can overwrite an agent's work

The editor reads once, auto-saves 600 ms after a quiet keystroke, flushes again
on close, and writes directly to its URL
(`Sources/fyolo/Editor/FileEditorView.swift:369-392,431-469`). That behavior is
already optimistic locally. Across a device connection, where an agent is
expected to edit the same checkout, blind whole-file replacement is dangerous.

The upload hash proves only that the new bytes arrived intact. `UploadOpen`
declares the new size and new sha256. `UploadCommit` accepts only `upload_id`.
The daemon never compares the current destination with the version the editor
read, and `rename` replaces whatever is there
(`fyolod/src/files.rs:589-659,709-744`). This sequence loses data:

1. The editor reads revision A.
2. The agent writes revision B.
3. The viewer edits A and uploads revision C.
4. Commit atomically replaces B with C.

No torn file appears, but B is gone. Atomicity is not conflict handling.

Require compare-and-swap semantics. `fs.read` must return a base revision that a
save can present: a content hash is strongest; a stable tuple of file identity,
mtime, size, and mode may be acceptable if its failure cases are documented.
Commit must reject a changed destination without replacing it. The viewer then
keeps the dirty buffer and offers Reload, Save Anyway, or a diff. A reconnect
must retry the same conditional save, not silently drop the precondition.

Permission preservation is also unimplemented. `DirEntry` carries name, kind,
size, mtime, and symlink target, but no mode
(`fyolod/src/protocol.rs:206-242`). `FsFile` carries size, offset, length, and
truncation, also no mode (`fyolod/src/protocol.rs:642-652`). If the client omits
`mode`, commit sets the replacement to `0644`
(`fyolod/src/files.rs:734-743`). Saving an executable script removes its execute
bits. ACLs and extended attributes are lost too because the dotfile replaces the
inode. Either the daemon preserves destination metadata on replacement or the
wire must return enough metadata for the client to send it back. The RFC's
current “`mode` preserves permissions” sentence is unsupported.

Finally, remote save is asynchronous while `FileEditorView.close()` is
synchronous and dismisses immediately after `writeIfNeeded()`. The design must
say what happens to a dirty buffer when save is in flight, the device drops, the
user switches sessions, or the app quits. A local `URL` plus an error string is
not enough ownership for that state.

## Watchers need a device-side budget

The daemon does share one watcher per canonical root across clients. That part
is sound. The resource cost is still material on the machine running the agent:

- `RecommendedWatcher` watches the root recursively
  (`fyolod/src/resource.rs:472-498`). On Linux that consumes inotify watches for
  the directory tree.
- The first subscription starts a breadth-first name-index walk of the entire
  root (`fyolod/src/files.rs:226-279,377-403`). “Idle priority” here is cooperative
  yielding, not an operating-system I/O priority.
- The watch and index remain alive for five minutes after the last subscriber.
- The current Files view stays mounted while another inspector tab covers it,
  and a collapsed inspector parks refreshes without stopping its local watcher
  (`Sources/fyolo/FileBrowser/FileBrowserView.swift:40-48,62-87,126-148`). Copying
  that lifetime to the device keeps remote work alive while nobody can see it.

Reaching a machine already authorizes file reads as that SSH user. It does not
authorize an unbounded recursive watch and index over `$HOME`, `/`, or a large
monorepo. A modal trust prompt is not the useful control. Opening a registered
workspace can be consent, but loose sessions must not automatically turn their
spawn directory into a watched workspace.

The RFC needs a budget: subscribe only for visible or explicitly cached
workspaces, cap live watchers and index memory per daemon, evict least-recently
used idle roots, surface watch-limit failure, and test a large repo on Linux.
The root must come from the workspace registry or an explicit user action, not
from whichever `.host` path won first.

## Unreachable must not fall back to local

The wrong-filesystem defect is most likely to return during failure. A device
source that cannot connect must remain a device source. It may show cached data,
but it must never ask `inspectorProjectPath` for a substitute.

The RFC needs a state table for at least:

| State | Read panes | Mutations and editor |
| --- | --- | --- |
| Reconnecting | Keep the last applied tree or diff, label it stale, and retain the resource cursor | Disable new mutations; keep dirty editor buffers locally |
| Reconnected with continuity | Apply replay after the subscribe acknowledgement | Resume a pending conditional save only with its original base revision |
| Reconnected with `gap` | Full rescan before applying new events | Revalidate every open editor before saving |
| Daemon unavailable or incompatible | Name the device and the failure; offer the existing setup or repair action | Do not stage local files as substitutes |
| Workspace path missing or permission denied | Name the path and the device | Keep the session alive; let the user choose another registered workspace |
| Session ended while workspace remains reachable | The workspace may stay readable because it is not owned by the session | Stop treating session lifetime as pane lifetime |

This depends on the accepted `FyolodConnection` health model. Without it, a
file channel can only turn end-of-stream into a generic pane error, while the
terminal link independently decides whether the session died. That is the
two-truth failure the connection object was introduced to remove.

## Search, Changes, and Issues have no staging

The RFC starts from all four affected panes, then stages only the Files pane.

| Pane | Device-side answer | Missing design |
| --- | --- | --- |
| Files | `fs.list`, `fs.read`, `fs:` watch, upload | Safe save, mutations, failure states, and a workspace-aware file identity |
| Search | `fs.search` exists | No stage wires streamed results, cancellation, result identity, or open-at-line into a device file. |
| Changes | `git:` status and `git.diff` exist | No stage wires them. The shipped pane also has History, Compare, Discard, and Ignore actions; the daemon has none of those. A remote subset needs an explicit UI contract. |
| Issues | GitHub list/detail stays viewer-side | The viewer first resolves `owner/repo` by running local git against `repoRoot` (`Sources/fyolo/Issues/IssuesPanelModel.swift:156-167`). The daemon exposes no origin URL or GitHub slug, and the toolbar hides Issues unless that same local probe succeeds (`Sources/fyolo/Git/InspectorTabsToolbar.swift:63-96`). |

Issues does not need to move OAuth credentials or GitHub HTTP calls onto the
device. It needs device-owned repository identity — at minimum the origin URL
or normalized forge slug — then the existing viewer-side provider can work.
Pull-request file expansion also needs device `fs.read` for context that GitHub's
patch omitted. Until that is designed, Stage 0 should show an honest unavailable
state rather than imply `WorkspaceSource` solves the pane.

Changes needs similar scoping. `fyolod/src/git.rs` can produce working-tree
status and one diff. It cannot back the pane's History and Compare tabs or its
Discard and Ignore actions. Either stage a read-only remote Changes subset and
hide unsupported controls, or add the missing verbs in a later RFC. “Git status
/ diff already exists” is not a plan for the shipped pane.

## The open questions are mostly already closed

| RFC question | Verdict |
| --- | --- |
| 1. Container or session? | Already answered by both architecture docs: workspace is `(device, canonical path)`, and a session references it. Use session association during migration; never let `.host` own the root. The remaining question is the wire and state migration for that reference. |
| 2. Trust? | Partly useful, but “trust” conflates read authority with resource cost. SSH access already grants reads. The open decision is which roots may start recursive watch/index work and what quota and eviction policy the daemon enforces. |
| 3. Multi-client? | Already answered. The device architecture requires viewers to connect directly to the device (`20260805-fyolod-device-architecture.md:136-162`), and `resource.rs` already supports independent subscribers sharing one watcher. The phone must not relay through the Mac. |
| 4. Plain SSH? | Already answered by `20260817-one-path-local-through-fyolod.md:68-77,1241-1252`: it stays terminal-only; the pane names the missing daemon and offers installation. |
| 5. Protobuf? | Outside this RFC and mostly answered. The protocol spec says control JSON is deliberate because it is low-rate and debuggability wins (`20260730-fyolod-session-protocol.md:175-197`), and rejects gRPC/protobuf/CBOR for the hot path (`:985-989`). A future payload-codegen proposal needs its own evidence. `WireProtocol.swift` is not the fyolod mirror. |

Replace the closed questions with the ones implementation cannot avoid:

1. What exact workspace reference is stored on a session and returned in
   `SessionInfo`, including adopted sessions and linked worktrees?
2. What revision token makes editor save conditional, and which metadata must
   survive replacement?
3. What pane state and dirty-buffer policy applies across reconnect, gap,
   incompatible daemon, missing root, session exit, and app quit?
4. Which parts of Search, Changes, History, Compare, and Issues ship at each
   stage?
5. What watcher/index quota applies per device, and what user action authorizes
   a new watched root?

## Required changes before approval

1. Replace `WorkspaceSource.local/device(alias:)` with a workspace reference
   keyed by stable device identity and canonical root. Keep route resolution and
   any temporary direct-local adapter below the pane API.
2. Decide that `.host` never owns a workspace. Add a session-to-workspace
   reference, a migration from `remoteCheckouts` and `fyolodRemoteCwd`, and the
   roster field needed for sessions created by another client.
3. Rewrite Stage 0 to stop every local read, watcher, git probe, drop target, and
   mutation for a device workspace. The four `sshHost` gates are not enough.
4. Make connection ownership an explicit prerequisite for Stages 1-2. State
   whether file channels use separate transports or the multiplexed device
   connection, and account for the protocol bump if they use the latter.
5. Correct Stage 2 capability negotiation and daemon enforcement:
   `resources` + `fs_watch` for the resource, `files` for list/read. Test replay
   inside the five-minute linger and `gap` recovery after it.
6. Design conditional save before Stage 3. Preserve executable mode and decide
   the treatment of ownership, ACLs, and extended attributes. Keep dirty buffers
   recoverable across asynchronous failure.
7. Add explicit stages for Search, the supported Changes subset, and repository
   identity for Issues. Hide or name every unsupported local-only action.
8. Define watcher eligibility, quotas, eviction, and large-repo/Linux acceptance
   tests. Do not automatically watch a loose session's home directory.
9. Define unreachable, reconnecting, gap, incompatible-daemon, missing-root,
   and session-ended presentation. None may fall back to this Mac's filesystem.
10. Remove the already-answered open questions and carry the unresolved wire,
    save, failure, pane-scope, and resource-budget decisions instead.
