import FyoloShared
import XCTest
@testable import fyolo

/// What the phone is told about where a checkout lives.
///
/// The roster used to be every workspace's projects poured into one list, so a
/// checkout on a Linux box and one on this Mac reached the phone looking
/// identical. Each container now names its workspace and that workspace's
/// machine — the middle two levels of Device → Workspace → Project → Session,
/// which the flat list had been dropping.
@MainActor
final class CompanionRosterWorkspaceTests: XCTestCase {
    private func makeStore(workspaces: [Workspace], projects: [Project]) -> FyoloStore {
        let defaults = UserDefaults(suiteName: "companion-roster-\(UUID().uuidString)")
            ?? UserDefaults.standard
        return FyoloStore(
            workspaces: workspaces, projects: projects,
            settings: AppSettings(defaults: defaults))
    }

    private func project(_ name: String, in workspace: Workspace) -> Project {
        Project(
            workspaceID: workspace.id, name: name, path: "/tmp/\(name)",
            branch: "main", sessions: [])
    }

    func testEveryContainerNamesItsWorkspaceAndMachine() {
        let home = Workspace(name: "Sessions", terminals: [Session(title: "Terminal 1")])
        let box = Workspace(name: "ukvps", deviceAlias: "ukvps")
        let store = makeStore(
            workspaces: [home, box],
            projects: [project("fyolo", in: home), project("api", in: box)])

        let roster = store.companionRoster()

        XCTAssertEqual(
            roster.projects.map { [$0.name, $0.workspaceName, $0.deviceAlias ?? "—"] },
            [
                ["Terminals", "Sessions", "—"],
                ["fyolo", "Sessions", "—"],
                ["api", "ukvps", "ukvps"],
            ],
            "containers ride in workspace order, each naming its scope and machine"
        )
        XCTAssertEqual(
            roster.projects.map(\.workspaceID),
            [home.id.uuidString, home.id.uuidString, box.id.uuidString])
    }

    /// The loose sections used to have their workspace spliced into the name
    /// ("Work — Terminals") because there was nowhere else to put it. With the
    /// workspace on the wire that is the same job done twice.
    func testLooseSectionsAreNotNamedAfterTheirWorkspace() {
        let work = Workspace(
            name: "Work", terminals: [Session(title: "Terminal 1")],
            chats: [Session(title: "Chat 1")])
        let store = makeStore(workspaces: [work, Workspace(name: "Personal")], projects: [])

        let roster = store.companionRoster()

        XCTAssertEqual(roster.projects.map(\.name), ["Terminals", "Chats"])
        XCTAssertEqual(roster.projects.map(\.workspaceName), ["Work", "Work"])
    }

    /// A folder that is not a repo has no branch, and the sidebar's "—" is a glyph
    /// it draws in an empty column — never a branch name to hand another app.
    func testANonRepoReportsNoBranch() {
        let home = Workspace(name: "Sessions")
        var folder = project("notes", in: home)
        folder.branch = "—"
        let store = makeStore(workspaces: [home], projects: [folder])

        XCTAssertEqual(store.companionRoster().projects.first?.branch, "")
    }
}
