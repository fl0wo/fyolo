import FyoloShared
import Foundation

/// The test-run plane: a project's Vitest runs as the device recorded them
/// (`fyolod/src/test_runs.rs`).
///
/// The runs are reported by the test runner itself, from inside the session,
/// through a reporter fyolod adds beside the user's own
/// (`fyolod/src/node_integration.rs`). Nothing here reads a terminal. The list
/// and each run's detail are requests. Live progress is the `tests:` resource,
/// whose events each replace one run's row.
extension Fyolod {
    /// Its own channel, like the git plane's: a channel that did not negotiate
    /// `test_runs` would be refused every verb here.
    static let testRunCapabilities = ["resources", "test_runs"]

    static func testRunsResource(root: String) -> String { "tests:\(root)" }

    struct TestCounts: Decodable, Sendable, Equatable {
        var passed = 0
        var failed = 0
        var skipped = 0
    }

    /// One run as a row. `state` is `running`, `passed`, `failed` or
    /// `interrupted`; anything newer reads as finished without a verdict.
    struct TestRunSummary: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        let root: String
        let state: String
        /// Unix milliseconds.
        let startedAt: UInt64
        let durationMs: UInt64
        let counts: TestCounts
        let filesTotal: Int
        let filesDone: Int
        let package: String?
        let session: String?
        let commandId: String?
        let command: String?
        let argv: [String]

        var isRunning: Bool { state == "running" }
        var startedDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt) / 1000) }

        private enum CodingKeys: String, CodingKey {
            case id, root, state, startedAt, durationMs, counts, filesTotal, filesDone
            case package, session, commandId, command, argv
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            root = try container.decode(String.self, forKey: .root)
            state = try container.decode(String.self, forKey: .state)
            startedAt = try container.decode(UInt64.self, forKey: .startedAt)
            durationMs = try container.decodeIfPresent(UInt64.self, forKey: .durationMs) ?? 0
            counts = try container.decodeIfPresent(TestCounts.self, forKey: .counts) ?? TestCounts()
            filesTotal = try container.decodeIfPresent(Int.self, forKey: .filesTotal) ?? 0
            filesDone = try container.decodeIfPresent(Int.self, forKey: .filesDone) ?? 0
            package = try container.decodeIfPresent(String.self, forKey: .package)
            session = try container.decodeIfPresent(String.self, forKey: .session)
            commandId = try container.decodeIfPresent(String.self, forKey: .commandId)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            argv = try container.decodeIfPresent([String].self, forKey: .argv) ?? []
        }
    }

    struct TestRunDetail: Decodable, Sendable, Equatable {
        var files: [TestFileResult] = []
        var failures: [TestFailure] = []

        private enum CodingKeys: String, CodingKey { case files, failures }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            files = try container.decodeIfPresent([TestFileResult].self, forKey: .files) ?? []
            failures = try container.decodeIfPresent([TestFailure].self, forKey: .failures) ?? []
        }
    }

    struct TestFileResult: Decodable, Sendable, Equatable {
        let path: String
        let state: String
        let project: String?
        let tests: [TestCaseResult]

        private enum CodingKeys: String, CodingKey { case path, state, project, tests }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
            project = try container.decodeIfPresent(String.self, forKey: .project)
            tests = try container.decodeIfPresent([TestCaseResult].self, forKey: .tests) ?? []
        }
    }

    struct TestCaseResult: Decodable, Sendable, Equatable {
        let name: String
        let state: String
    }

    /// `kind` is `test`, `module` (a file that failed to load) or `unhandled`
    /// (an error outside any test).
    struct TestFailure: Decodable, Sendable, Equatable {
        let kind: String
        let file: String?
        let test: String?
        let message: String?
        let diff: String?
        /// `path:line`, relative to the run's root.
        let location: String?
    }

    /// A project's runs, newest first, and the root the device files them
    /// under: the repository `root` sits in, which names the `tests:` resource.
    static func testRuns(
        route: FyolodRoute, root: String, limit: Int = 6
    ) async throws -> (root: String, runs: [TestRunSummary]) {
        let result = try await testRunsRequest(
            route: route, WireTestRunsResult.self, operation: "test runs"
        ) { seq in
            try encodeControl(TestRunsOperation(root: root, limit: UInt64(limit), seq: seq))
        }
        return (result.root, result.runs)
    }

    /// One run's per-file results and failures. `nil` for a run the device no
    /// longer keeps.
    static func testRunDetail(
        route: FyolodRoute, root: String, id: String
    ) async throws -> TestRunDetail? {
        try await testRunsRequest(
            route: route, WireTestRunDetailResult.self, operation: "test run \(id)"
        ) { seq in
            try encodeControl(TestRunDetailOperation(root: root, id: id, seq: seq))
        }.detail
    }

    /// Subscribes to a project's live runs. `root` must be the key `testRuns`
    /// returned. Every first subscribe is a gap: the caller lists, then applies
    /// what arrives.
    static func watchTestRuns(
        route: FyolodRoute,
        root: String,
        onRun: @escaping @Sendable (_ seq: UInt64, TestRunSummary) -> Void,
        onInterrupted: @escaping @Sendable () -> Void
    ) async throws -> ResourceSubscription {
        try await offMain {
            try subscribeResource(
                route: route,
                caps: testRunCapabilities,
                resource: testRunsResource(root: root),
                requiring: ["test_runs"],
                onEvent: { payload in
                    guard let event = try? testRunsDecoder().decode(WireTestRunChanged.self, from: payload)
                    else { return }
                    onRun(event.seq, event.run)
                },
                onInterrupted: onInterrupted)
        }.subscription
    }

    /// Replies to these verbs are not in the shared decode table — nothing but
    /// this plane reads them — so they arrive as `.unknown` and are decoded
    /// against `Wire`, the git plane's read-tier shape.
    private static func testRunsRequest<Wire: Decodable & Sendable>(
        route: FyolodRoute, _ wire: Wire.Type, operation: String,
        encode: @escaping @Sendable (UInt64) throws -> Data
    ) async throws -> Wire {
        try await offMain {
            try withPooledRequest(route: route, caps: testRunCapabilities) { call, channel in
                guard channel.capabilities.contains("test_runs") else {
                    throw FyolodClientError.unsupportedCapability("test_runs")
                }
                try call.send(payload: encode(call.seq))
                while true {
                    let frame = try call.next(
                        timeoutSeconds: connectTimeoutSeconds, operation: operation)
                    guard frame.kind == .control else { continue }
                    let reply = try decodeControl(frame.payload)
                    if case .error(let failure) = reply {
                        throw FyolodClientError.requestFailed(failure.message)
                    }
                    guard case .unknown = reply else { continue }
                    return try testRunsDecoder().decode(Wire.self, from: frame.payload)
                }
            }
        }
    }

    private struct TestRunsOperation: Encodable {
        let op = "test_runs"
        let root: String
        let limit: UInt64
        let seq: UInt64
    }

    private struct TestRunDetailOperation: Encodable {
        let op = "test_run_detail"
        let root: String
        let id: String
        let seq: UInt64
    }

    private struct WireTestRunsResult: Decodable, Sendable {
        let root: String
        let runs: [TestRunSummary]
    }

    private struct WireTestRunDetailResult: Decodable, Sendable {
        let detail: TestRunDetail?
    }

    struct WireTestRunChanged: Decodable, Sendable {
        let seq: UInt64
        let run: TestRunSummary
    }

    static func testRunsDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
