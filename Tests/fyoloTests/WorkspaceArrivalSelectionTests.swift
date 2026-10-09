import XCTest

@testable import fyolo

/// Where a workspace switch lands. Coming back to a scope resumes it on the row
/// it was left on, because the terminal, the split group, and the inspector tab
/// all follow the selected session — landing on the first row instead reopens
/// something the user was not working on.
@MainActor
final class WorkspaceArrivalSelectionTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-arrival-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "workspace-arrival-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// Scratch storage for both settings layers: a test must not rewrite the
    /// settings file or the defaults domain of the fyolo the user is running.
    private func makeStore(_ workspaces: [Workspace]) -> FyoloStore {
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
        return FyoloStore(workspaces: workspaces, settings: settings)
    }

    private func workspace(_ name: String, sessions: Int) -> Workspace {
        Workspace(
            name: name,
            terminals: (1...sessions).map { Session(title: "\(name) \($0)", agent: .terminal) })
    }

    func testAWorkspaceComesBackToTheSessionItWasLeftOn() {
        let first = workspace("Left", sessions: 3)
        let second = workspace("Right", sessions: 2)
        let store = makeStore([first, second])

        store.selectedSessionID = first.terminals[2].id
        store.selectedSessionID = second.terminals[0].id

        XCTAssertEqual(store.arrivalSelection(inWorkspace: first.id), first.terminals[2].id)
        XCTAssertEqual(store.arrivalSelection(inWorkspace: second.id), second.terminals[0].id)
    }

    /// A scope nobody has been in has nothing to remember, so it opens on its
    /// first row the way it always did.
    func testAnUnvisitedWorkspaceLandsOnItsFirstSession() {
        let first = workspace("Left", sessions: 2)
        let store = makeStore([first])

        XCTAssertEqual(store.arrivalSelection(inWorkspace: first.id), first.terminals[0].id)
    }

    /// The remembered row can be closed from elsewhere — a deep link, the phone,
    /// the daemon — so the arrival is validated against the live roster instead of
    /// selecting a session the tree no longer holds.
    func testAClosedSessionFallsBackToTheFirstRow() {
        let first = workspace("Left", sessions: 3)
        let store = makeStore([first])

        store.selectedSessionID = first.terminals[2].id
        store.workspaces[0].terminals.removeLast()

        XCTAssertEqual(store.arrivalSelection(inWorkspace: first.id), first.terminals[0].id)
    }

    /// An empty scope shows the welcome state rather than borrowing a row from
    /// the one it replaced.
    func testAnEmptyWorkspaceSelectsNothing() {
        let empty = Workspace(name: "Empty")
        let store = makeStore([empty])

        XCTAssertNil(store.arrivalSelection(inWorkspace: empty.id))
    }
}
