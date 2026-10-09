import Foundation

/// One daemon session this app destroyed, remembered by the name the daemon
/// knows it by and the route it lived on. The record is both halves of the
/// closed-session journal (RFC 20260830 §D1/§D3): a **pending kill** when the
/// route was unreachable at close time — retried on the next successful roster
/// refresh — and the proof that a roster row of this name is this app's own
/// orphan, to be killed on sight rather than adopted. The journal, not name
/// shape, decides "mine": two installs share one per-uid daemon roster, so a
/// UUID-shaped name alone proves nothing about whose session it is.
///
/// A record's identity is the `(name, sshAlias)` pair, never the bare name:
/// adopted sessions keep device-given names ("build"), so the same name can
/// legitimately exist on several machines at once, and one route's close must
/// not erase another's pending kill.
struct ClosedDaemonSession: Codable, Hashable {
    /// The daemon-side session name (the app session's uuid, or the name an
    /// adopted session already had on the device).
    var name: String
    /// The SSH alias of the route the session lived on; `nil` for this Mac.
    var sshAlias: String?
    /// The machine the session lived on, when a handshake had revealed it. The
    /// sweep matches a record by this **or** by alias, so a box whose
    /// `~/.ssh/config` alias was renamed after the close still settles its
    /// pending kill. Absent from records written before the field existed,
    /// which then match by alias alone.
    var deviceID: String?
    /// The daemon's own id for the session that was destroyed — minted fresh
    /// per creation, so a reused *name* never reuses the id. The sweep kills a
    /// roster row only when its id matches; a same-named row with a different
    /// id is a new session the close never promised to end. Absent when no
    /// attach or roster revealed the id before the close; such a record matches
    /// by name only when the name is app-authored — a UUID, which nothing else
    /// mints. An id-less record with a device-given name ("build") never kills:
    /// it proves nothing about which same-named session it meant, so the sweep
    /// drops it instead (`journalClaims`).
    var daemonID: String?
}

/// The session tree's on-disk home: it owns the file location and the JSON
/// (de)serialization, so `FyoloStore` only ever hands it values. Live state
/// (terminal surfaces, per-session activity) is intentionally never written —
/// shells restart fresh, so only the tree and the current selection persist.
struct StateFile {
    struct Snapshot: Codable {
        /// The workspaces the sidebar scopes by. Absent in every state file
        /// written before workspaces existed, which is what `legacyProjects`
        /// below is decoded for.
        var workspaces: [Workspace]?
        /// The workspace the sidebar was showing when the app closed.
        var currentWorkspaceID: Workspace.ID?
        var projects: [Project]
        /// The same `projects` key read through the pre-workspace shape, filled
        /// in only when `workspaces` is missing. A project no longer carries the
        /// funnel fields (`kind`, `sshHost`), so the upgrade has to read the file
        /// the way it was written — see `WorkspaceMigration`.
        var legacyProjects: [WorkspaceMigration.LegacyProject]?
        var selectedSessionID: Session.ID?
        /// The single split layout builds before split *groups* used to write.
        /// Never written anymore, only decoded — `FyoloStore.restored` migrates
        /// it into `splitGroups` as one group.
        var splitRoot: SplitNode?
        /// The split groups (see `FyoloStore.splitGroups`). Optional so state
        /// files written before groups existed still decode.
        var splitGroups: [SplitNode]?
        /// Each session's inspector layout, keyed by session `id.uuidString`. Only the
        /// durable subset is written — the tab and the open *file* — since a diff / PR /
        /// trace is a snapshot of data that gets re-fetched (see `FyoloStore.InspectorState`).
        /// Optional so older state files still decode.
        var inspectorLayouts: [String: InspectorLayout]?
        /// The session each workspace was last left on, keyed by workspace
        /// `id.uuidString` (see `FyoloStore.workspaceSelections`). Optional so older
        /// state files still decode.
        var workspaceSelections: [String: Session.ID]?
        /// The closed-session journal (see `ClosedDaemonSession`). Persisted so a
        /// close made while a route was offline — or right before a crash — is
        /// still honored by the next launch's roster sweep. Optional so older
        /// state files still decode.
        var closedDaemonSessions: [ClosedDaemonSession]?

        init(
            workspaces: [Workspace]?,
            currentWorkspaceID: Workspace.ID?,
            projects: [Project],
            selectedSessionID: Session.ID?,
            splitRoot: SplitNode? = nil,
            splitGroups: [SplitNode]?,
            inspectorLayouts: [String: InspectorLayout]?,
            workspaceSelections: [String: Session.ID]? = nil,
            closedDaemonSessions: [ClosedDaemonSession]? = nil
        ) {
            self.workspaces = workspaces
            self.currentWorkspaceID = currentWorkspaceID
            self.projects = projects
            self.selectedSessionID = selectedSessionID
            self.splitRoot = splitRoot
            self.splitGroups = splitGroups
            self.inspectorLayouts = inspectorLayouts
            self.workspaceSelections = workspaceSelections
            self.closedDaemonSessions = closedDaemonSessions
        }

        private enum CodingKeys: String, CodingKey {
            case workspaces, currentWorkspaceID, projects, selectedSessionID, splitRoot,
                 splitGroups, inspectorLayouts, workspaceSelections, closedDaemonSessions
        }

        /// `projects` is decoded twice on an upgrade — once as the live shape, once
        /// as the shape the file was written in — because one JSON key has to
        /// answer to both until every user's state file has been rewritten. A file
        /// that already has `workspaces` skips the second read.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces)
            currentWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .currentWorkspaceID)
            projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
            legacyProjects = workspaces == nil
                ? try c.decodeIfPresent([WorkspaceMigration.LegacyProject].self, forKey: .projects)
                : nil
            selectedSessionID = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
            splitRoot = try c.decodeIfPresent(SplitNode.self, forKey: .splitRoot)
            splitGroups = try c.decodeIfPresent([SplitNode].self, forKey: .splitGroups)
            inspectorLayouts = try c.decodeIfPresent(
                [String: InspectorLayout].self, forKey: .inspectorLayouts)
            workspaceSelections = try c.decodeIfPresent(
                [String: UUID].self, forKey: .workspaceSelections)
            closedDaemonSessions = try c.decodeIfPresent(
                [ClosedDaemonSession].self, forKey: .closedDaemonSessions)
        }

        /// `legacyProjects` never round-trips: it is the same `projects` array read
        /// a second way, and writing it would leave a duplicate key in the file.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(workspaces, forKey: .workspaces)
            try c.encodeIfPresent(currentWorkspaceID, forKey: .currentWorkspaceID)
            try c.encode(projects, forKey: .projects)
            try c.encodeIfPresent(selectedSessionID, forKey: .selectedSessionID)
            try c.encodeIfPresent(splitGroups, forKey: .splitGroups)
            try c.encodeIfPresent(inspectorLayouts, forKey: .inspectorLayouts)
            try c.encodeIfPresent(workspaceSelections, forKey: .workspaceSelections)
            try c.encodeIfPresent(closedDaemonSessions, forKey: .closedDaemonSessions)
        }
    }

    /// The persisted slice of a session's inspector layout: which tab, and the file it
    /// had open (validated for existence on restore, since the file may have been deleted
    /// or its worktree removed while the app was closed).
    struct InspectorLayout: Codable {
        var tab: InspectorTab
        var filePath: String?
        var fileLine: Int?
        var fileReadOnly: Bool?
    }

    let url = AppChannel.supportDirectory

    private var stateURL: URL { url.appendingPathComponent("state.json") }

    /// The saved snapshot, or `nil` on first launch or an unreadable/corrupt file
    /// (in which case the caller seeds fresh state rather than failing).
    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Best-effort, atomic write. Failures are logged rather than crashing —
    /// losing a save is recoverable, trapping is not. Indented and key-sorted so
    /// the file reads like a config and diffs cleanly, not a one-line blob.
    func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: stateURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("fyolo: failed to persist state: \(error)\n".utf8))
        }
    }
}
