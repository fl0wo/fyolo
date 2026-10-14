import XCTest

@testable import fyolo

/// The run capsule's recents: one entry per task, newest first, ten per project.
final class RunHistoryTests: XCTestCase {
    private func task(_ name: String, in folder: String = "/repo") -> RunTask {
        RunTask(name: name, command: "npm run \(name)", directory: URL(fileURLWithPath: folder))
    }

    func testRunningATaskAgainMovesItToTheFrontWithoutADuplicate() {
        var history = RunHistory()
        history.record(task("build"), session: nil, in: "/repo")
        history.record(task("test"), session: nil, in: "/repo")
        history.record(task("build"), session: nil, in: "/repo")
        XCTAssertEqual(history.recents(in: "/repo").map(\.task.name), ["build", "test"])
        XCTAssertEqual(history.selectedRecord(in: "/repo")?.task.name, "build")
    }

    func testTheListKeepsTheNewestTen() {
        var history = RunHistory()
        for index in 0..<11 { history.record(task("t\(index)"), session: nil, in: "/repo") }
        let names = history.recents(in: "/repo").map(\.task.name)
        XCTAssertEqual(names.count, RunHistory.limit)
        XCTAssertEqual(names.first, "t10")
        XCTAssertFalse(names.contains("t0"))
    }

    func testEachProjectHasItsOwnRecents() {
        var history = RunHistory()
        history.record(task("web"), session: nil, in: "/web")
        history.record(task("api", in: "/api"), session: nil, in: "/api")
        XCTAssertEqual(history.recents(in: "/web").map(\.task.name), ["web"])
        XCTAssertEqual(history.recents(in: "/api").map(\.task.name), ["api"])
        history.clear(in: "/web")
        XCTAssertTrue(history.recents(in: "/web").isEmpty)
        XCTAssertEqual(history.recents(in: "/api").count, 1)
    }

    func testAPickedTaskStaysSelectedUntilAnotherRun() {
        var history = RunHistory()
        history.record(task("build"), session: nil, in: "/repo")
        history.record(task("test"), session: nil, in: "/repo")
        history.select(task("build").id, in: "/repo")
        XCTAssertEqual(history.selectedRecord(in: "/repo")?.task.name, "build")
        history.record(task("lint"), session: nil, in: "/repo")
        XCTAssertEqual(history.selectedRecord(in: "/repo")?.task.name, "lint")
    }

    func testAClosedTerminalIsForgottenButTheTaskStays() {
        var history = RunHistory()
        let session = UUID()
        history.record(task("dev"), session: session, in: "/repo")
        history.forgetSessions { $0 == session }
        XCTAssertNil(history.recents(in: "/repo").first?.sessionID)
        XCTAssertEqual(history.recents(in: "/repo").count, 1)
    }

    func testTheHistoryRoundTripsThroughTheStateFile() throws {
        var history = RunHistory()
        history.record(task("dev"), session: UUID(), in: "/repo")
        let decoded = try JSONDecoder().decode(RunHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }

    /// The Info pane is gone; a layout saved on it must not fail the state file,
    /// which would take the whole session tree with it.
    func testARemovedInspectorTabReadsAsFiles() throws {
        let layout = try JSONDecoder().decode(
            StateFile.InspectorLayout.self, from: Data(#"{"tab":"info"}"#.utf8))
        XCTAssertEqual(layout.tab, .files)
    }

    @MainActor
    func testStoppingATaskBeforeItsCommandIsTypedKeepsItFromBeingTyped() {
        let runTasks = RunTasks()
        let build = task("build")
        let attempt = runTasks.willStart(build, in: "/repo")
        XCTAssertTrue(runTasks.cancelPendingStart(build))
        XCTAssertFalse(runTasks.isRunning(build))
        XCTAssertFalse(runTasks.claimDelivery(build, attempt: attempt))
    }

    @MainActor
    func testRunningATaskAgainWhileItStartsTypesItOnce() {
        let runTasks = RunTasks()
        let build = task("build")
        let first = runTasks.willStart(build, in: "/repo")
        let second = runTasks.willStart(build, in: "/repo")
        XCTAssertFalse(runTasks.claimDelivery(build, attempt: first))
        XCTAssertTrue(runTasks.claimDelivery(build, attempt: second))
        XCTAssertFalse(runTasks.cancelPendingStart(build), "a typed command is stopped in its terminal")
    }
}
