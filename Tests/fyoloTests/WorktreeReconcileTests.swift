import XCTest
@testable import fyolo

/// The merge of git's worktrees into a project's rows. The canonical spellings
/// arrive as data — resolved off the main actor together with the git read — so
/// these need no filesystem at all.
@MainActor
final class WorktreeReconcileTests: XCTestCase {
    /// A project holding `worktrees`, with one session in the worktree spelled
    /// `sessionPath` when given.
    private func makeStore(
        worktrees: [String], sessionPath: String? = nil
    ) -> FyoloStore {
        let workspace = Workspace(name: "Test")
        var sessions: [Session] = []
        if let sessionPath {
            var session = Session(title: "claude")
            session.worktreePath = sessionPath
            sessions = [session]
        }
        let project = Project(
            workspaceID: workspace.id, name: "repo", path: "/tmp/scratch/repo",
            branch: "main", sessions: sessions,
            worktrees: worktrees.map { Worktree(path: $0) })
        let defaults = UserDefaults(suiteName: "worktree-reconcile-\(UUID().uuidString)")
            ?? UserDefaults.standard
        return FyoloStore(
            workspaces: [workspace], projects: [project],
            settings: AppSettings(defaults: defaults))
    }

    /// Two rows for one checkout exist on disk today, left by the lexical
    /// matching this pass replaces — and they persist exactly where a session
    /// holds one of them. Merging them has to carry that session onto the row
    /// that survives: sessions are matched to rows by exact path, so one left on
    /// the spelling that lost belongs to no row, renders nowhere in the sidebar,
    /// and stays in the saved roster where nothing short of editing state on
    /// disk reaches it.
    func testMergingDuplicateRowsCarriesSessionsOntoTheSurvivor() {
        // The session is on the old lexical spelling — the row git's realpath
        // never matched, which is why a second one was appended beside it.
        let store = makeStore(
            worktrees: ["/private/tmp/scratch/wt-a", "/tmp/scratch/wt-a"],
            sessionPath: "/tmp/scratch/wt-a")
        let projectID = store.projects[0].id

        // Both spellings are one checkout, which is what git reports.
        store.applyDiscoveredWorktrees(
            WorktreeService.Reconcile(
                discovered: ["/private/tmp/scratch/wt-a"], stale: [], absent: [],
                canonical: [
                    "/private/tmp/scratch/wt-a": "/tmp/scratch/wt-a",
                    "/tmp/scratch/wt-a": "/tmp/scratch/wt-a",
                ]),
            to: projectID)

        let merged = store.projects[0]
        XCTAssertEqual(merged.worktrees.count, 1)
        XCTAssertEqual(merged.sessions[0].worktreePath, merged.worktrees[0].path,
                       "the session must still name a row that exists")
    }

    /// A worktree git no longer reports keeps its row while a session is in it,
    /// and that session is left on the spelling it already had.
    func testAGitAbsentWorktreeKeepsItsRowAndItsSessionsSpelling() {
        let store = makeStore(
            worktrees: ["/tmp/scratch/wt-gone"], sessionPath: "/tmp/scratch/wt-gone")
        let projectID = store.projects[0].id

        store.applyDiscoveredWorktrees(
            WorktreeService.Reconcile(
                discovered: [], stale: [], absent: [],
                canonical: ["/tmp/scratch/wt-gone": "/tmp/scratch/wt-gone"]),
            to: projectID)

        XCTAssertEqual(store.projects[0].worktrees.map { $0.path }, ["/tmp/scratch/wt-gone"])
        XCTAssertEqual(store.projects[0].sessions[0].worktreePath, "/tmp/scratch/wt-gone")
    }

    /// Duplicates collapse on the git-absent path too, which is this feature's
    /// own case: a worktree whose folder was deleted, kept in the sidebar only
    /// because a session is still in it. Those rows never reach the merge above,
    /// so both used to survive every pass — the sessions moving onto the first
    /// and the second left behind, empty and anchored by a key nothing would
    /// clear.
    func testDuplicateRowsCollapseEvenWhenGitReportsNeither() {
        let store = makeStore(
            worktrees: ["/private/tmp/scratch/wt-gone", "/tmp/scratch/wt-gone"],
            sessionPath: "/tmp/scratch/wt-gone")
        let projectID = store.projects[0].id

        store.applyDiscoveredWorktrees(
            WorktreeService.Reconcile(
                discovered: [], stale: [], absent: [],
                canonical: [
                    "/private/tmp/scratch/wt-gone": "/tmp/scratch/wt-gone",
                    "/tmp/scratch/wt-gone": "/tmp/scratch/wt-gone",
                ]),
            to: projectID)

        let project = store.projects[0]
        XCTAssertEqual(project.worktrees.count, 1, "one row for one checkout")
        XCTAssertEqual(project.sessions[0].worktreePath, project.worktrees[0].path)
    }

    /// A row git still registers but cannot offer is kept *and* marked, so the
    /// sidebar stops offering to start work in a checkout that is not there while
    /// the row itself stays reachable for removal. The mark clears the moment git
    /// offers the worktree again.
    func testAStaleRowIsKeptButMarkedSoNothingStartsWorkInIt() {
        let store = makeStore(worktrees: ["/tmp/scratch/wt-gone"])
        let projectID = store.projects[0].id

        store.applyDiscoveredWorktrees(
            WorktreeService.Reconcile(
                discovered: [], stale: ["/tmp/scratch/wt-gone"], absent: ["/tmp/scratch/wt-gone"],
                canonical: ["/tmp/scratch/wt-gone": "/tmp/scratch/wt-gone"]),
            to: projectID)

        XCTAssertEqual(store.projects[0].worktrees.count, 1, "the row stays, so Remove is reachable")
        XCTAssertTrue(store.projects[0].worktrees[0].missing)

        // The folder comes back and git offers the worktree again.
        store.applyDiscoveredWorktrees(
            WorktreeService.Reconcile(
                discovered: ["/tmp/scratch/wt-gone"], stale: [], absent: [],
                canonical: ["/tmp/scratch/wt-gone": "/tmp/scratch/wt-gone"]),
            to: projectID)
        XCTAssertFalse(store.projects[0].worktrees[0].missing)
    }

    /// A row kept only because a session is in it is not marked: git still offers
    /// that checkout, so there is somewhere to work.
    func testARowHeldBySessionAloneIsNotMarkedMissing() {
        let store = makeStore(
            worktrees: ["/tmp/scratch/wt-live"], sessionPath: "/tmp/scratch/wt-live")
        let projectID = store.projects[0].id

        store.applyDiscoveredWorktrees(
            WorktreeService.Reconcile(
                discovered: [], stale: [], absent: [],
                canonical: ["/tmp/scratch/wt-live": "/tmp/scratch/wt-live"]),
            to: projectID)

        XCTAssertEqual(store.projects[0].worktrees.count, 1)
        XCTAssertFalse(store.projects[0].worktrees[0].missing)
    }

    /// A path the off-main pass never saw — a row added since it started — is
    /// compared lexically for this round rather than resolved here, because
    /// resolving it would mean a `stat` on the main actor, on the very reconcile
    /// that fires while an agent is committing.
    func testAPathTheReconcileNeverSawIsStillMatched() {
        let store = makeStore(worktrees: ["/tmp/scratch/wt-new"])
        let projectID = store.projects[0].id
        let existing = store.projects[0].worktrees[0].id

        store.applyDiscoveredWorktrees(
            WorktreeService.Reconcile(discovered: ["/tmp/scratch/wt-new"], stale: [], absent: [], canonical: [:]),
            to: projectID)

        let rows = store.projects[0].worktrees
        XCTAssertEqual(rows.count, 1, "no second row for a checkout that already had one")
        XCTAssertEqual(rows[0].id, existing, "and the existing row is the one kept")
    }
}
