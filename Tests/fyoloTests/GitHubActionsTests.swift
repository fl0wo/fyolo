import XCTest
@testable import fyolo

/// The Actions pane's pure logic: what a run's status means, which pinned run
/// the toolbar chip shows, how a job log is cleaned up, and which bytes of it
/// are read.
@MainActor
final class GitHubActionsTests: XCTestCase {
    // MARK: Status

    func testPhaseFromStatusAndConclusion() {
        XCTAssertEqual(WorkflowRunPhase(status: "completed", conclusion: "success"), .succeeded)
        for failed in ["failure", "timed_out", "startup_failure"] {
            XCTAssertEqual(WorkflowRunPhase(status: "completed", conclusion: failed), .failed, failed)
        }
        for neutral in ["cancelled", "skipped", "neutral", "stale"] {
            XCTAssertEqual(WorkflowRunPhase(status: "completed", conclusion: neutral), .neutral, neutral)
        }
        XCTAssertEqual(WorkflowRunPhase(status: "completed", conclusion: "action_required"), .active)
        for active in ["queued", "in_progress", "waiting", "requested", "pending"] {
            XCTAssertEqual(WorkflowRunPhase(status: active, conclusion: nil), .active, active)
        }
    }

    func testGlyphTellsRunningFromQueued() {
        XCTAssertEqual(WorkflowStatusKind(status: "in_progress", conclusion: nil), .running)
        XCTAssertEqual(WorkflowStatusKind(status: "queued", conclusion: nil), .queued)
        XCTAssertEqual(WorkflowStatusKind(status: "completed", conclusion: "failure"), .failure)
        XCTAssertEqual(WorkflowStatusKind(status: "completed", conclusion: "cancelled"), .neutral)
    }

    // MARK: Chip priority

    private func run(_ id: Int, _ status: String, _ conclusion: String?, minutesAgo: Double) throws -> WorkflowRun {
        WorkflowRun(
            id: id, name: "w\(id)", displayTitle: nil, runNumber: id, runAttempt: 1, event: "push",
            status: status, conclusion: conclusion, workflowId: id, headBranch: "main",
            htmlUrl: try XCTUnwrap(URL(string: "https://github.com/acme/app/actions/runs/\(id)")),
            createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60),
            updatedAt: Date(timeIntervalSinceNow: -minutesAgo * 60),
            runStartedAt: nil, actor: nil)
    }

    func testAFailureOutranksNewerRunningAndPassingRuns() throws {
        let picked = PinnedWorkflowStatus.pick([
            try run(1, "completed", "success", minutesAgo: 1),
            try run(2, "in_progress", nil, minutesAgo: 2),
            try run(3, "completed", "failure", minutesAgo: 30),
        ])
        XCTAssertEqual(picked?.id, 3)
    }

    func testTheNewestFailureWinsAmongFailures() throws {
        let picked = PinnedWorkflowStatus.pick([
            try run(1, "completed", "failure", minutesAgo: 50),
            try run(2, "completed", "timed_out", minutesAgo: 5),
        ])
        XCTAssertEqual(picked?.id, 2)
    }

    func testWithoutFailuresTheNewestRunningRunWins() throws {
        let picked = PinnedWorkflowStatus.pick([
            try run(1, "completed", "success", minutesAgo: 1),
            try run(2, "queued", nil, minutesAgo: 9),
            try run(3, "in_progress", nil, minutesAgo: 3),
        ])
        XCTAssertEqual(picked?.id, 3)
    }

    func testAllSettledShowsTheNewest() throws {
        let picked = PinnedWorkflowStatus.pick([
            try run(1, "completed", "success", minutesAgo: 10),
            try run(2, "completed", "cancelled", minutesAgo: 2),
        ])
        XCTAssertEqual(picked?.id, 2)
        XCTAssertNil(PinnedWorkflowStatus.pick([]))
    }

    // MARK: Log parsing

    func testStripsTheByteOrderMarkTimestampsAndEscapes() {
        let lines = JobLogParser.lines(
            "\u{FEFF}2026-10-14T13:35:00.3615979Z Current runner version\r\n"
                + "2026-10-14T13:35:01.1000000Z \u{1B}[36;1mecho hi\u{1B}[0m\n"
                + "not a timestamp line\n")
        XCTAssertEqual(lines.map(\.text), ["Current runner version", "echo hi", "not a timestamp line"])
        XCTAssertTrue(lines.allSatisfy { $0.kind == .plain })
    }

    func testWorkflowCommandsBecomeLineKinds() {
        let lines = JobLogParser.lines("""
        2026-10-14T13:35:00.1Z ##[group]Run make test
        2026-10-14T13:35:00.2Z make: *** [test] Error 1
        2026-10-14T13:35:00.3Z ##[endgroup]
        2026-10-14T13:35:00.4Z ##[error]Process completed with exit code 2.
        2026-10-14T13:35:00.5Z ##[warning]Node 20 is deprecated
        2026-10-14T13:35:00.6Z ##[command]/usr/bin/git version
        2026-10-14T13:35:00.7Z [command]/usr/bin/git config --global --add safe.directory /w
        """)
        XCTAssertEqual(lines.map(\.kind), [.group, .plain, .error, .warning, .command, .command])
        XCTAssertEqual(lines.last?.text, "/usr/bin/git config --global --add safe.directory /w")
        XCTAssertEqual(lines.first?.text, "Run make test")
        XCTAssertEqual(lines[2].text, "Process completed with exit code 2.")
    }

    // MARK: Byte ranges

    func testTheFirstReadIsTheTail() {
        let window = JobLogWindow(size: 5_000_000)
        XCTAssertEqual(window.nextRange, (5_000_000 - JobLogWindow.chunkSize)..<5_000_000)
        XCTAssertEqual(JobLogWindow(size: 1_000).nextRange, 0..<1_000)
        XCTAssertNil(JobLogWindow(size: 0).nextRange)
    }

    func testLoadingEarlierWalksBackUntilTheStartOrTheCap() throws {
        var small = JobLogWindow(size: 700_000)
        small.didLoad(try XCTUnwrap(small.nextRange))
        XCTAssertEqual(small.nextRange, 0..<(700_000 - JobLogWindow.chunkSize))
        small.didLoad(try XCTUnwrap(small.nextRange))
        XCTAssertTrue(small.reachesFileStart)
        XCTAssertNil(small.nextRange)

        var large = JobLogWindow(size: 50_000_000)
        while let range = large.nextRange { large.didLoad(range) }
        XCTAssertEqual(large.loadedBytes, JobLogWindow.capacity)
        XCTAssertTrue(large.isAtCapacity)
    }

    func testAChunkFromMidFileHoldsBackItsSplitFirstLine() {
        let chunk = Data("ail of a line\nwhole line\nlast".utf8)
        let mid = JobLogWindow.splitPartialHead(chunk, atFileStart: false)
        XCTAssertEqual(String(decoding: mid.head, as: UTF8.self), "ail of a line")
        XCTAssertEqual(String(decoding: mid.body, as: UTF8.self), "whole line\nlast")

        let start = JobLogWindow.splitPartialHead(chunk, atFileStart: true)
        XCTAssertTrue(start.head.isEmpty)
        XCTAssertEqual(start.body, chunk)

        let noNewline = JobLogWindow.splitPartialHead(Data("all one line".utf8), atFileStart: false)
        XCTAssertEqual(noNewline.head.count, 12)
        XCTAssertTrue(noNewline.body.isEmpty)
    }

    // MARK: Pins

    func testPinsAreKeptPerRepositoryInPinOrder() {
        let suite = "fyolo.tests.pins.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let settings = AppSettings(
            defaults: defaults,
            settingsStore: SettingsStore(defaults: defaults, fileURL: file, domainName: suite))
        settings.setWorkflow(7, pinned: true, in: "Acme/App")
        settings.setWorkflow(3, pinned: true, in: "acme/app")
        settings.setWorkflow(9, pinned: true, in: "acme/other")
        XCTAssertEqual(settings.pinnedWorkflowIDs(in: "acme/app"), [7, 3])
        settings.setWorkflow(7, pinned: false, in: "acme/app")
        XCTAssertEqual(settings.pinnedWorkflowIDs(in: "ACME/APP"), [3])
        settings.setWorkflow(3, pinned: false, in: "acme/app")
        XCTAssertNil(settings.pinnedWorkflows["acme/app"])
        XCTAssertEqual(settings.pinnedWorkflowIDs(in: "acme/other"), [9])
    }
}
