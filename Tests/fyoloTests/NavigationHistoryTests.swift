import XCTest

@testable import fyolo

/// Back and forward. The history's rules are replayed as click sequences against what VS Code and
/// every browser do; the store's half checks that real navigations — a file, a session, a tab —
/// each become one step and that a step back restores the place, not just its name.
@MainActor
final class NavigationHistoryTests: XCTestCase {
    // MARK: The rules

    func testBackAndForwardWalkTheVisitsAndANewVisitDropsWhatWasAhead() {
        var history = NavigationHistory<String>()
        for place in ["a", "b", "c"] { history.visit(place) }
        XCTAssertEqual(history.goBack(where: { _ in true }), "b")
        XCTAssertEqual(history.goBack(where: { _ in true }), "a")
        XCTAssertNil(history.goBack(where: { _ in true }))
        XCTAssertEqual(history.current, "a")
        XCTAssertEqual(history.goForward(where: { _ in true }), "b")
        history.visit("d")
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(where: { _ in true }), "b")
        XCTAssertEqual(history.goBack(where: { _ in true }), "a")
    }

    func testArrivingWhereYouAreIsNoStep() {
        var history = NavigationHistory<String>()
        history.visit("a")
        history.visit("a")
        XCTAssertFalse(history.canGoBack)
    }

    func testAPlaceThatNoLongerExistsIsSkippedAndForgotten() {
        var history = NavigationHistory<String>()
        for place in ["a", "gone", "b"] { history.visit(place) }
        XCTAssertEqual(history.goBack(where: { $0 != "gone" }), "a")
        XCTAssertEqual(history.goForward(where: { $0 != "gone" }), "b")
        XCTAssertNil(history.goForward(where: { _ in true }))
        XCTAssertEqual(history.goBack(where: { _ in true }), "a", "the dead place was dropped")
    }

    func testNothingLiveBehindLeavesTheCurrentPlaceAlone() {
        var history = NavigationHistory<String>()
        for place in ["gone", "a"] { history.visit(place) }
        XCTAssertNil(history.goBack(where: { $0 != "gone" }))
        XCTAssertEqual(history.current, "a")
    }

    func testTheOldestPlacesAreForgottenPastTheLimit() {
        var history = NavigationHistory<Int>()
        history.limit = 3
        for place in 0 ..< 10 { history.visit(place) }
        XCTAssertEqual(history.back, [6, 7, 8])
    }

    func testAPlaceIsWhereNotWhatItCarries() {
        let change = GitChange(path: "a.swift", status: .modified, isUntracked: false)
        var diff = GitDiffRequest(repoRoot: "/repo", change: change)
        let before = NavigationPlace(session: nil, tab: .changes, diff: diff)
        diff.siblings = [change, GitChange(path: "b.swift", status: .added, isUntracked: false)]
        XCTAssertEqual(before, NavigationPlace(session: nil, tab: .changes, diff: diff))

        let file = URL(fileURLWithPath: "/repo/a.swift")
        XCTAssertNotEqual(
            NavigationPlace(session: nil, tab: .files, file: file, line: 3),
            NavigationPlace(session: nil, tab: .files, file: file, line: 40),
            "a jump inside one file is a step")
    }

    // MARK: The store

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("navigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "navigation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeStore(sessions: [Session]) -> FyoloStore {
        var workspace = Workspace(name: "Default")
        workspace.terminals = sessions
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(
                defaults: defaults,
                fileURL: directory.appendingPathComponent("settings.json"),
                domainName: suiteName))
        return FyoloStore(workspaces: [workspace], settings: settings)
    }

    /// Lets the burst of changes a click makes settle into its one recorded step.
    private func settle() async {
        await Task.yield()
        let settled = expectation(description: "the main queue drained")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
    }

    private func file(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("text\n".utf8).write(to: url)
        return url
    }

    func testFilesSessionsAndTabsAreStepsAndBackRestoresEachPlace() async throws {
        let first = Session(title: "Terminal 1")
        let second = Session(title: "Terminal 2")
        let store = makeStore(sessions: [first, second])
        store.selectedSessionID = first.id
        await settle()

        let a = try file("a.swift")
        let b = try file("b.swift")
        store.openFileInEditor(a)
        await settle()
        store.openFileInEditor(b, at: 12)
        await settle()
        store.selectedSessionID = second.id
        await settle()
        store.inspectorTab = .changes
        await settle()

        store.navigateBack()
        await settle()
        XCTAssertEqual(store.selectedSessionID, second.id)
        XCTAssertEqual(store.inspectorTab, .files)

        store.navigateBack()
        await settle()
        XCTAssertEqual(store.selectedSessionID, first.id)
        XCTAssertEqual(store.openFileURL, b)
        XCTAssertEqual(store.openFileLine, 12, "back lands on the line, not the top")

        store.navigateBack()
        await settle()
        XCTAssertEqual(store.openFileURL, a)

        store.navigateForward()
        await settle()
        XCTAssertEqual(store.openFileURL, b)
        XCTAssertTrue(store.navigationHistory.canGoForward, "a step back is not a new visit")
    }

    func testAJumpFromTheEditorComesBackToTheLineItLeft() async throws {
        let session = Session(title: "Terminal 1")
        let store = makeStore(sessions: [session])
        store.selectedSessionID = session.id
        let a = try file("a.ts")
        let b = try file("b.ts")
        store.openFileInEditor(a)
        await settle()

        store.noteEditorLine(30)
        store.openFileInEditor(b, at: 2)
        await settle()

        store.navigateBack()
        await settle()
        XCTAssertEqual(store.openFileURL, a)
        XCTAssertEqual(store.openFileLine, 30)
    }

    func testMaximizingAFileIsAStepOfItsOwn() async throws {
        let session = Session(title: "Terminal 1")
        let store = makeStore(sessions: [session])
        store.selectedSessionID = session.id
        let readme = try file("README.md")
        store.openFileInEditor(readme)
        await settle()
        store.inspectorMaximized = true
        await settle()

        store.navigateBack()
        await settle()
        XCTAssertEqual(store.openFileURL, readme, "back un-maximizes, it does not close")
        XCTAssertFalse(store.inspectorMaximized)

        store.navigateForward()
        await settle()
        XCTAssertEqual(store.openFileURL, readme)
        XCTAssertTrue(store.inspectorMaximized)
    }

    func testAClosedSessionIsSteppedOver() async throws {
        let first = Session(title: "Terminal 1")
        let second = Session(title: "Terminal 2")
        let third = Session(title: "Terminal 3")
        let store = makeStore(sessions: [first, second, third])
        await settle()
        for session in [first, second, third] {
            store.selectedSessionID = session.id
            await settle()
        }
        store.workspaces[0].terminals.removeAll { $0.id == second.id }

        store.navigateBack()
        await settle()
        XCTAssertEqual(store.selectedSessionID, first.id)
    }
}
