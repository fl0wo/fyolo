import XCTest
@testable import fyolo

/// `SessionSlotIndex` — the map `FyoloStore.locate(_:)` reads instead of walking
/// the tree.
///
/// The index answers "where does this session live" with an array index, and an
/// index that describes the tree as it was one mutation ago is a wrong answer,
/// not a slow one: the callers use it to remove, insert and reorder. So the test
/// that matters is agreement — after every shape of edit the sidebar can make,
/// the index must return exactly what the walk it replaced would have returned,
/// for every session and for an id nothing holds.
///
/// `linearLocate` below is that walk, kept verbatim from the implementation this
/// replaced, so the comparison has a real reference rather than a restatement of
/// the new code.
final class SessionSlotIndexTests: XCTestCase {
    // MARK: - The reference

    /// The pre-index `locate(_:)`, unchanged: workspaces first (terminals, then
    /// chats), then projects, first match winning.
    private func linearLocate(
        _ id: Session.ID, workspaces: [Workspace], projects: [Project]
    ) -> SessionSlot? {
        for (w, workspace) in workspaces.enumerated() {
            if let s = workspace.terminals.firstIndex(where: { $0.id == id }) {
                return .terminals(workspace: w, session: s)
            }
            if let s = workspace.chats.firstIndex(where: { $0.id == id }) {
                return .chats(workspace: w, session: s)
            }
        }
        for (p, project) in projects.enumerated() {
            if let s = project.sessions.firstIndex(where: { $0.id == id }) {
                return .project(project: p, session: s)
            }
        }
        return nil
    }

    /// Rebuilds the index and asserts it agrees with the walk for every session in
    /// the tree, and that both refuse an id nothing holds.
    private func assertAgreement(
        _ workspaces: [Workspace], _ projects: [Project], _ step: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let index = SessionSlotIndex(workspaces: workspaces, projects: projects)
        var ids = workspaces.flatMap { $0.looseSessions.map(\.id) }
        ids += projects.flatMap { $0.sessions.map(\.id) }
        for id in ids {
            XCTAssertEqual(index[id], linearLocate(id, workspaces: workspaces, projects: projects),
                           "\(step): slot disagrees for \(id)", file: file, line: line)
        }
        let stranger = UUID()
        XCTAssertNil(index[stranger], "\(step): invented a slot for a session nothing holds",
                     file: file, line: line)
        XCTAssertEqual(Set(index.sessionIDs), Set(ids),
                       "\(step): the index and the tree hold different sessions",
                       file: file, line: line)
    }

    private func session(_ title: String) -> Session {
        Session(title: title, agent: .terminal)
    }

    private func project(_ name: String, in workspace: Workspace.ID, sessions: [Session]) -> Project {
        Project(workspaceID: workspace, name: name, path: "/code/\(name)",
                branch: "main", sessions: sessions)
    }

    // MARK: - Agreement across every edit the sidebar can make

    func testTheIndexAgreesWithTheWalkThroughEveryTreeEdit() {
        var alpha = Workspace(name: "Alpha")
        alpha.terminals = [session("a1"), session("a2")]
        alpha.chats = [session("ac1")]
        var beta = Workspace(name: "Beta")
        beta.terminals = [session("b1")]
        var workspaces = [alpha, beta]
        var projects = [
            project("fyolo", in: alpha.id, sessions: [session("p1"), session("p2")]),
            project("vibewizard", in: beta.id, sessions: [session("q1")]),
        ]
        assertAgreement(workspaces, projects, "initial")

        // Insert into the middle of a project's roster: every session below it
        // moves down one, which is exactly what a stale index gets wrong.
        projects[0].sessions.insert(session("p1.5"), at: 1)
        assertAgreement(workspaces, projects, "insert into a project")

        // Insert at the head of a workspace's terminals.
        workspaces[0].terminals.insert(session("a0"), at: 0)
        assertAgreement(workspaces, projects, "insert into terminals")

        // Remove from the head of a project's roster.
        projects[0].sessions.remove(at: 0)
        assertAgreement(workspaces, projects, "remove from a project")

        // Reorder within one roster — the sidebar's drag-to-reorder.
        workspaces[0].terminals.swapAt(0, workspaces[0].terminals.count - 1)
        assertAgreement(workspaces, projects, "reorder terminals")

        // Move a session between workspaces, and between the two loose
        // collections while it travels: its slot changes case, not just its index.
        let travelling = workspaces[0].terminals.removeLast()
        workspaces[1].chats.append(travelling)
        assertAgreement(workspaces, projects, "move between workspaces")

        // Move a project's session into a workspace's chats — a project row
        // becoming a loose one, which crosses from the second pass to the first.
        let promoted = projects[1].sessions.removeFirst()
        workspaces[0].chats.insert(promoted, at: 0)
        assertAgreement(workspaces, projects, "project session becomes loose")

        // Reorder the projects themselves: no session moves inside its roster,
        // but every project slot's owning index does.
        projects.swapAt(0, 1)
        assertAgreement(workspaces, projects, "reorder projects")

        // Remove the first workspace: every later workspace slot shifts up one.
        workspaces.removeFirst()
        assertAgreement(workspaces, projects, "remove a workspace")

        // Remove a project, then empty the tree entirely.
        projects.removeFirst()
        assertAgreement(workspaces, projects, "remove a project")
        projects.removeAll()
        for i in workspaces.indices {
            workspaces[i].terminals.removeAll()
            workspaces[i].chats.removeAll()
        }
        assertAgreement(workspaces, projects, "empty tree")
    }

    /// A session filed in two places at once should not exist, but if one ever
    /// does the index must resolve it the way the walk did — the workspace copy,
    /// not the project's — or a mutation lands on the wrong array.
    func testADuplicatedSessionResolvesToTheWorkspaceCopy() {
        var workspace = Workspace(name: "Alpha")
        let duplicate = session("both")
        workspace.terminals = [session("a1"), duplicate]
        let projects = [project("fyolo", in: workspace.id, sessions: [duplicate])]
        let index = SessionSlotIndex(workspaces: [workspace], projects: projects)
        XCTAssertEqual(index[duplicate.id], .terminals(workspace: 0, session: 1))
        XCTAssertEqual(index[duplicate.id],
                       linearLocate(duplicate.id, workspaces: [workspace], projects: projects))
    }

    // MARK: - What the index is for

    /// The complexity change, measured rather than asserted: the walk costs the
    /// whole tree per lookup, the index costs a hash. The sidebar does this per
    /// row per render, so the number that matters is a full sweep — one lookup
    /// for every session, which is what one sidebar render amounts to.
    ///
    /// No timing assertion: a wall-clock threshold on a shared CI machine is a
    /// flaky test. The numbers print, and the shape of the curve is the evidence.
    func testLookupCostAgainstTheWalkItReplaced() {
        for count in [100, 200, 400] {
            var workspace = Workspace(name: "Alpha")
            workspace.terminals = (0..<(count / 4)).map { session("t\($0)") }
            workspace.chats = (0..<(count / 4)).map { session("c\($0)") }
            let filed = (0..<(count / 2)).map { session("p\($0)") }
            let projects = (0..<10).map { p in
                project("repo\(p)", in: workspace.id,
                        sessions: Array(filed[(p * filed.count / 10)..<((p + 1) * filed.count / 10)]))
            }
            let workspaces = [workspace]
            var ids = workspaces.flatMap { $0.looseSessions.map(\.id) }
            ids += projects.flatMap { $0.sessions.map(\.id) }
            XCTAssertEqual(ids.count, count)

            // Both loops sum the resolved session indices rather than asserting
            // per lookup: an `XCTAssert` inside the timed loop costs more than the
            // lookup does and would flatten the very difference being measured.
            // The sums are compared afterwards, which keeps the loops honest work.
            var walkSum = 0
            let walkStart = CFAbsoluteTimeGetCurrent()
            for id in ids {
                walkSum += linearLocate(id, workspaces: workspaces, projects: projects)?
                    .sessionIndex ?? -1
            }
            let walk = CFAbsoluteTimeGetCurrent() - walkStart

            let index = SessionSlotIndex(workspaces: workspaces, projects: projects)
            var indexedSum = 0
            let indexedStart = CFAbsoluteTimeGetCurrent()
            for id in ids { indexedSum += index[id]?.sessionIndex ?? -1 }
            let indexed = CFAbsoluteTimeGetCurrent() - indexedStart
            XCTAssertEqual(walkSum, indexedSum, "the two sweeps resolved different slots")

            let buildStart = CFAbsoluteTimeGetCurrent()
            _ = SessionSlotIndex(workspaces: workspaces, projects: projects)
            let build = CFAbsoluteTimeGetCurrent() - buildStart

            print(String(format:
                "sessions=%d  sweep: walk %.3f ms, index %.3f ms (%.1fx)  rebuild %.3f ms",
                count, walk * 1000, indexed * 1000, walk / max(indexed, 1e-9), build * 1000))
        }
    }
}
