---
title: A project carries its machine — delete the host container
status: done
type: rfc
created: 2026-08-18
updated: 2026-08-31
related:
  - 20260818-one-workspace-source.review-codex.md
  - 20260818-remote-git-plane.md
  - 20260817-one-path-local-through-fyolod.md
  - 20260814-remote-to-device.md
  - 20260805-fyolod-device-architecture.md
  - 20260730-fyolod-session-protocol.md
---

# A project carries its machine — delete the host container

> Make a project on another machine the same object as a project on this Mac,
> distinguished by a `location` field rather than by living under a host node —
> and make opening one use the same picker, backed by `fs.list` instead of
> `NSOpenPanel`.

## 0. What changed since the first draft

The first draft of this RFC proposed a `WorkspaceSource` enum read by the
inspector panes. Its review (`20260818-one-workspace-source.review-codex.md`) rejected
that shape on two counts, both correct:

- keying a device by SSH **alias** mistakes a route for identity, so one box
  reached by LAN, WAN, and Tailscale names forks into three workspaces, when
  `DeviceContext.swift:214-225` already prefers `deviceID`;
- keeping `.local` as a lasting public case preserves the local special-case
  that `20260817-one-path-local-through-fyolod.md` exists to delete.

It also found that `.host` provably cannot own a workspace root
(`hostContainer` keeps one root per alias, first-writer-wins), and that the
staging leaned on a workspace identity nothing on the wire supplies.

This draft answers all of that with a smaller idea, taken from Zed: **do not
introduce a workspace type at all — put the machine on the `Project` and delete
the container.** A project already is a root, a name, and a set of sessions. It
only lacks a machine.

The Stage 0 correctness work already implemented on `feat/one-workspace-source`
survives this rewrite unchanged: it stops the inspector reading local data for a
remote session, which is true under either model.

## 1. Prior art: how Zed models a remote project

Read from a checkout of `zed-industries/zed` at `main`. These paths are in
Zed's repository, not this one.

The whole answer is one type (`crates/workspace/src/persistence/model.rs:43-46`):

```rust
pub enum SerializedWorkspaceLocation {
    Local,
    Remote(RemoteConnectionOptions),
}
```

A persisted workspace is `{ workspace_id, location, paths, window_id }`
(`:55-63`). **The machine is a field on the workspace, never a parent node.**
There is no host container in Zed's project tree, and the recents list is one
flat list where `Local` and `Remote(..)` rows are rendered side by side
(`crates/recent_projects/src/recent_projects.rs:1476-1519`).

The thing that superficially resembles fyolo's `.host` container is settings
only (`crates/settings_content/src/settings_content.rs:1284-1305`):

```rust
pub struct SshConnection {
    pub host: String,
    pub username: Option<String>,
    pub port: Option<u16>,
    pub args: Vec<String>,
    pub projects: collections::BTreeSet<RemoteProject>,   // RemoteProject { paths: Vec<String> }
    pub nickname: Option<String>,
    pub upload_binary_over_ssh: Option<bool>,
    …
}
```

That `projects` set is a **per-server memory of paths you have opened**, which
feeds the picker. It is not the project tree and nothing reads it as one.

### 1.1 Why adding a remote project feels like adding a local one

One abstraction with two backends (`crates/project/src/project.rs:996-999`):

```rust
pub enum DirectoryLister {
    Project(Entity<Project>),
    Local(Entity<Project>, Arc<dyn Fs>),
}
```

`Project::list_directory(query)` dispatches on it (`:973-1003`): a local project
walks `Fs`; a remote one sends
`proto::ListRemoteDirectory { path, config: { is_dir: true } }` (`:4981-4984`),
which the remote server answers in `handle_list_remote_directory`
(`crates/remote_server/src/headless_project.rs:1153-1180`).

Both feed the **same picker component**. The smoothness is not UI polish; it is
the refusal to own two pickers.

### 1.2 Where fyolo is ahead, and must not copy down

Zed keys a remote workspace by `RemoteConnectionOptions`
(`crates/remote/src/remote_client.rs:1323-1329`) — Ssh/Wsl/Docker connection
parameters. That is a **route**. Zed has no stable machine identity, so one box
reached two ways is two workspaces.

fyolod's `host_id` from `hello_ok` is a real device identity, and
`DeviceContext.swift:214-225` already prefers it once both ends know it. Take
Zed's *shape*; keep fyolo's identity. This is the first draft's alias mistake,
fixed at the root rather than papered over.

## 2. The model

```swift
enum ProjectLocation: Codable, Hashable {
    /// This Mac.
    case local
    /// A device, by the identity its daemon reported at handshake. The route
    /// used to reach it is resolved separately and may change.
    case device(id: String)
}
```

`Project` (`Models.swift:67`) gains `location`. `ProjectKind.host`
(`Models.swift:34`) is **deleted as a container**. `Project.sshHost`
(`:105`) survives only as the bootstrap route until a handshake resolves
`deviceID` (`:111`), matching the alias-then-identity split the device
architecture already defines.

A project is then, on both machines, the same object: a name, a root, a
location, sessions, worktrees. Everything downstream — the inspector, git, the
window title, Open Project…, the `+` menu — asks the project where it lives and
stops asking the *session* what road it took.

`remoteCheckouts: [String: String]` (`:128`) is superseded: it maps one device
to one checkout per project, which cannot express a base checkout plus two
worktrees on the same box. Those become ordinary projects with
`location == .device(id)`.

## 3. One lister, two backends

```swift
protocol DirectoryLister {
    func list(_ path: String) async throws -> [DirectoryItem]
}
```

- **Local** — `FileManager`, and `NSOpenPanel` remains available as the native
  affordance for `.local`.
- **Device** — `FsList` (`fyolod/src/protocol.rs:473`), which is fyolo's
  `ListRemoteDirectory`. It already exists, is batched and `seq`-stamped, and is
  smoke-tested. **No protocol change.**

`presentOpenProjectPanel` (`FyoloStore+ProjectActions.swift:583-592`) becomes
"Open Project… on \<device\>", choosing its lister from the device the window is
on. `addProject(at:)` (`:597-614`) gains the location and stops calling
`resolveBranchLabel` against the local filesystem for a device project.

This is also the fix for a defect noted but never filed: Open Project… is an
`NSOpenPanel`, which can only browse volumes mounted on this Mac, and it carries
no `DeviceMenuTag`, so it never learns which device the window is showing.

## 4. Loose sessions — the one thing Zed does not answer

Zed has no session outside a project, so its model has no place for a bare
remote shell. fyolo does: today that shell lives in the `.host` container this
RFC deletes.

**Decision: a per-device Terminals group.** It is the same presentation grouping
as the existing local `.terminals` funnel — a home for project-less sessions,
scoped to a device. It is explicitly **not** a workspace: it owns no root, and
nothing may read a root from it. That preserves the review's actual objection
("the container never owns a root") while keeping loose remote shells reachable.

## 5. Staging

### Stage 0 — Stop reading local data for a remote session *(implemented)*

Already built on `feat/one-workspace-source`: the inspector no longer resolves
this Mac's files, git, or search for a session running elsewhere. Independent of
the model below, and it stands.

*Gate:* `grep -rn 'sshHost' Sources/fyolo/FileBrowser/ | wc -l` → 0; a remote
session opened from a local project row shows an empty state naming the device.
**Met:** build clean, six tests in `InspectorWorkspaceTests` green, including
`testRemoteSessionUnderALocalProjectOffersNoLocalRoot`.

### Stage 1 — Put the location on the project

Add `ProjectLocation`, migrate existing state, and delete `.host` as a
container, moving its sessions into the per-device Terminals group (§4).
Everything that branches on `session.sshHost` or `session.fyolodRemoteHost` to
decide *where data lives* switches to the project's location. Panes stay as
honest as Stage 0 left them — no new capability.

This is the persistence-touching stage: `StateFile` writes the session tree, so
the migration must be forward-only and must not lose a project whose `.host`
container is gone.

*Gate:* a state file written by the previous release opens with every project
and session intact; no `ProjectKind.host` remains; a device project round-trips
across relaunch.

### Stage 2 — The device lister and Open Project… on a device

`DirectoryLister` with both backends, one picker, and Open Project… routed to
the device the window is on. This is where "add a remote project" becomes as
smooth as adding a local one.

*Gate:* Open Project… while on ukvps browses ukvps, and the chosen folder
appears in the sidebar as an ordinary project with a device badge.

### Stage 3 — Back the panes with `fs.*`

`fs.list` and `fs.read` for the Files pane; `fs:` subscription with cursor
resume. Deliberately after Stage 2, because a device project must exist before
there is a root to list.

Capability note from the review: the `fs:` resource needs `resources` (and the
protocol names `fs_watch`), while list/read need `files`. Capabilities are fixed
at `hello`, so one channel must negotiate all of them or reopen.

*Gate:* replay inside the watcher's 300-second linger
(`fyolod/src/resource.rs:51`) is exact; past it, `gap: true` correctly forces a
full rescan. The first draft's "sleep the Mac and it catches up incrementally"
gate was wrong and is replaced by this pair.

### Stage 4 — Editing and mutations

Conditional save (a base revision from `fs.read`, a commit that refuses a
changed destination), then rename/trash/restore/mkdir. Both need protocol
additions; the first draft's claim that Stages 0-3 needed none was false for
save and is corrected here.

### Stage 5 — Delete SFTP

`SSHFileSystemProvider.swift` (531 lines), `SFTPClient.swift` (878),
`RemoteFileTree.swift`.

*Gate:* `grep -rn 'SFTP' Sources/ | wc -l` → 0.

## 6. What this supersedes from the review

| Review requirement | Answer |
| --- | --- |
| Replace alias-keyed source with stable device identity | §2 — `.device(id:)`, identity not route |
| No lasting public `.local` case | §2 — location is a project field, not a source enum every pane switches on |
| `.host` never owns a workspace | §4 — deleted; loose sessions get a presentation-only group |
| Session-to-workspace reference and its migration | Superseded — a session belongs to a project, which carries the location. No new reference type, no roster field for sessions this app created |
| Stage 0 must cut every local read, not four gates | Implemented; see §5 Stage 0 |
| Stage 2 capability negotiation and linger/gap gates | §5 Stage 3 |
| Conditional save before Stage 3 | §5 Stage 4 |
| Connection ownership as a prerequisite | Still open — see §7.1 |
| Search/Changes/Issues staging | Partly here, partly `20260818-remote-git-plane.md`; Issues repository identity remains unsolved |
| Watcher quota and eligibility | Still open — see §7.2 |

## 7. Still open

1. **Connection ownership.** The review requires a durable per-device
   connection before resource subscriptions, while `withControlChannel`
   (`FyolodClient.swift:1025-1042`) is one-shot. Stage 3 depends on this; Stages
   1-2 do not, since `fs.list` is a request/response.
2. **Watcher budget.** Which roots may start a recursive watch and name index on
   someone else's machine, with what quota and eviction. Opening a project is a
   plausible consent boundary now that a project is the unit — but a loose
   session's spawn directory must not silently become a watched root.
3. **A session adopted from another client.** It reports no project, so the
   viewer cannot place it. It lands in the device's Terminals group, which is
   correct but loses the workspace it may really belong to. A roster field would
   fix it; that is a protocol change and is not required before Stage 3.
4. **Issues.** The pane resolves `owner/repo` by running local git against
   `repoRoot`. A device project has no local root, so Issues needs device-owned
   repository identity — at minimum the origin URL.
5. **Worktrees on a device.** They become ordinary device projects under this
   model, but `WorktreeService` enumerates via local `git worktree list`. The
   device architecture's workspace registry is the intended owner.

## 8. Non-goals

- No buffer or LSP mirror; the terminal is the editor beyond a preview.
- No mount, in any form.
- No new transport, and no protocol change before Stage 4.
- No multi-root projects. Zed's workspaces hold several paths
  (`RemoteProject { paths: Vec<String> }`); fyolo's hold one, and this RFC does
  not change that.
