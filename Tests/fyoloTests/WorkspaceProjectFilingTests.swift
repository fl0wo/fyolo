import XCTest
@testable import fyolo

/// Where a project may be filed, now that the workspace is what says which
/// machine it is on.
///
/// Two consequences the hierarchy has and the flat model did not: a project
/// cannot be moved to a workspace on another machine, because the move would not
/// move the directory; and a checkout that records no machine of its own is on
/// its workspace's, which is what every project written from here on looks like.
@MainActor
final class WorkspaceProjectFilingTests: XCTestCase {
    private func makeStore(workspaces: [Workspace], projects: [Project]) -> FyoloStore {
        let defaults = UserDefaults(suiteName: "workspace-filing-\(UUID().uuidString)")
            ?? UserDefaults.standard
        return FyoloStore(
            workspaces: workspaces, projects: projects,
            settings: AppSettings(defaults: defaults))
    }

    private func project(_ name: String, in workspace: Workspace) -> Project {
        Project(workspaceID: workspace.id, name: name, path: "/code/\(name)",
                branch: "main", sessions: [])
    }

    /// The rows a submenu offers, so a test can read the menu the way a user does.
    private func rows(of item: SidebarMenuItem?) -> [String] {
        guard case .submenu(_, let rows) = item else { return [] }
        return rows.compactMap { row in
            if case .action(let label, _) = row { return label }
            return nil
        }
    }

    // MARK: - Moving between workspaces

    func testAProjectMovesToAnotherWorkspaceOnItsOwnMachine() {
        let work = Workspace(name: "Work", isAutoCreated: false)
        let side = Workspace(name: "Side", isAutoCreated: false)
        let api = project("api", in: work)
        let store = makeStore(workspaces: [work, side], projects: [api])

        store.moveProject(api.id, toWorkspace: side.id)

        XCTAssertEqual(store.projects.first?.workspaceID, side.id)
    }

    /// A checkout is a directory on one box. Moving its row to a workspace on
    /// another machine would leave the row naming a path that machine has never
    /// had — putting the repo over there is a clone, a different verb.
    func testAProjectIsNotMovedToAWorkspaceOnAnotherMachine() {
        let work = Workspace(name: "Work", isAutoCreated: false)
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps", isAutoCreated: true)
        let api = project("api", in: work)
        let store = makeStore(workspaces: [work, ukvps], projects: [api])

        store.moveProject(api.id, toWorkspace: ukvps.id)

        XCTAssertEqual(store.projects.first?.workspaceID, work.id, "the row stays where it is")
    }

    /// The menu offers only what the move would accept: a row that is refused on
    /// click is worse than no row.
    func testTheMoveMenuOffersOnlyWorkspacesOnTheSameMachine() {
        let work = Workspace(name: "Work", isAutoCreated: false)
        let side = Workspace(name: "Side", isAutoCreated: false)
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps", isAutoCreated: true)
        let api = project("api", in: work)
        let store = makeStore(workspaces: [work, side, ukvps], projects: [api])

        let menu = moveToWorkspaceMenuItem(store: store, project: api)

        XCTAssertEqual(rows(of: menu), ["Side"])
    }

    /// And disappears when the only other workspaces are on other machines.
    func testTheMoveMenuIsAbsentWithNoTargetOnTheSameMachine() {
        let work = Workspace(name: "Work", isAutoCreated: false)
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps", isAutoCreated: true)
        let api = project("api", in: work)
        let store = makeStore(workspaces: [work, ukvps], projects: [api])

        XCTAssertNil(moveToWorkspaceMenuItem(store: store, project: api))
    }

    // MARK: - The order the switcher shows

    /// Ordered by who made it, not by which machine it is on: every workspace
    /// names a machine now, so ordering by the device would push a workspace the
    /// user named and filled with checkouts on one box to the bottom of their own
    /// list.
    func testFyolosOwnWorkspacesSortAfterTheOnesTheUserMade() {
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps", isAutoCreated: true)
        let onABox = Workspace(name: "Ship auth", deviceAlias: "devbox", isAutoCreated: false)
        let work = Workspace(name: "Work", isAutoCreated: false)
        let store = makeStore(workspaces: [ukvps, onABox, work], projects: [])

        XCTAssertEqual(store.orderedWorkspaces.map(\.name), ["Ship auth", "Work", "ukvps"])
    }

    // MARK: - What a checkout that names no machine means

    /// A checkout filed in a box's workspace and recording no machine of its own
    /// is on that box. Reading its silence as "this Mac" — which is what it meant
    /// in a file written before the hierarchy — would tear every remote checkout
    /// off its workspace.
    func testACheckoutThatRecordsNoMachineIsOnItsWorkspacesMachine() {
        let ukvps = Workspace(name: "ukvps", deviceAlias: "ukvps", isAutoCreated: true)
        let api = project("api", in: ukvps)

        let (workspaces, projects) = WorkspaceMigration.reconcile(
            workspaces: [ukvps], projects: [api])

        XCTAssertEqual(workspaces.count, 1, "nothing to split: the checkout claims nothing")
        XCTAssertEqual(workspaces.first?.device, .ssh(alias: "ukvps"))
        XCTAssertEqual(projects.first?.workspaceID, ukvps.id)
    }

    /// The launch after the upgrade. The first `reconcile` reads the machine each
    /// checkout recorded and files the tree by it; the save that follows drops
    /// those keys, because the workspace is where the machine lives now. The
    /// second launch must then leave the same tree alone — the round trip is what
    /// makes this a different input from the first pass.
    func testTheLaunchAfterAnUpgradeChangesNothing() throws {
        let scope = Workspace(name: "Work", terminals: [Session(title: "Terminal 1")])
        var remote = project("api", in: scope)
        remote.legacyDevice = KnownDevice(alias: "ukvps", deviceID: "h_aaaa")

        let upgraded = WorkspaceMigration.reconcile(
            workspaces: [scope], projects: [project("fyolo", in: scope), remote])
        XCTAssertEqual(upgraded.workspaces.count, 2, "the mixed workspace splits on the upgrade")

        // What the state file holds afterwards: `legacyDevice` is decoded, never
        // written, so the next launch decodes projects that name no machine.
        let saved = try JSONDecoder().decode(
            [Project].self, from: try JSONEncoder().encode(upgraded.projects))
        XCTAssertTrue(saved.allSatisfy { $0.legacyDevice == nil })

        let relaunched = WorkspaceMigration.reconcile(
            workspaces: upgraded.workspaces, projects: saved)

        XCTAssertEqual(relaunched.workspaces, upgraded.workspaces)
        XCTAssertEqual(relaunched.projects.map(\.workspaceID), saved.map(\.workspaceID))
    }
}
