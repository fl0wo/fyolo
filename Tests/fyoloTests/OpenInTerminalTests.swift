import XCTest

@testable import fyolo

/// The file tree's Open in Integrated Terminal: the shell must start in the row's
/// folder, and the row must land where ⌘T would put it — beside the selected
/// session — so a folder of the project on screen opens inside that project.
@MainActor
final class OpenInTerminalTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-in-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "open-in-terminal-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeStore(projectSessions: [Session]) -> (FyoloStore, Project.ID) {
        let workspace = Workspace(name: "Default")
        let project = Project(
            workspaceID: workspace.id, name: "app", path: directory.path,
            branch: "main", sessions: projectSessions)
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
        let store = FyoloStore(workspaces: [workspace], projects: [project], settings: settings)
        return (store, project.id)
    }

    func testAFolderOfTheSelectedProjectOpensInsideThatProject() throws {
        let anchor = Session(title: "Terminal 1")
        let (store, projectID) = makeStore(projectSessions: [anchor])
        store.selectedSessionID = anchor.id
        let folder = directory.appendingPathComponent("Sources").path

        store.addTerminal(in: folder)

        let project = try XCTUnwrap(store.projects.first { $0.id == projectID })
        XCTAssertEqual(project.sessions.count, 2)
        let opened = try XCTUnwrap(project.sessions.last)
        XCTAssertEqual(opened.agent, .terminal)
        XCTAssertEqual(opened.spawnDirectory, folder)
        XCTAssertEqual(store.selectedSessionID, opened.id)
    }

    func testTheSelectedSessionsWorktreeCarriesOver() throws {
        var anchor = Session(title: "Terminal 1")
        anchor.worktreePath = directory.appendingPathComponent("wt").path
        let (store, projectID) = makeStore(projectSessions: [anchor])
        store.selectedSessionID = anchor.id

        store.addTerminal(in: directory.appendingPathComponent("wt/lib").path)

        let opened = try XCTUnwrap(store.projects.first { $0.id == projectID }?.sessions.last)
        XCTAssertEqual(opened.worktreePath, anchor.worktreePath)
    }

    func testWithNothingSelectedItIsALooseTerminal() throws {
        let (store, _) = makeStore(projectSessions: [])
        let folder = directory.path

        store.addTerminal(in: folder)

        let opened = try XCTUnwrap(store.workspaces.first?.terminals.last)
        XCTAssertEqual(opened.spawnDirectory, folder)
        XCTAssertEqual(store.selectedSessionID, opened.id)
    }
}
