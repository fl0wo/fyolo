import AppKit
import Combine
import Foundation

// MARK: - Models

/// A workflow file in `.github/workflows`, as `/actions/workflows` lists it.
struct Workflow: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let path: String
    /// `active`, or one of the `disabled_*` states — a disabled workflow never runs.
    let state: String
    let htmlUrl: URL?

    var isActive: Bool { state == "active" }
}

struct WorkflowActor: Decodable, Hashable, Sendable {
    let login: String
}

/// One execution of a workflow.
struct WorkflowRun: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    /// The workflow's name at the time of the run.
    let name: String?
    /// What GitHub shows as the run's title: the commit message or PR title.
    let displayTitle: String?
    let runNumber: Int
    let runAttempt: Int?
    let event: String
    let status: String?
    let conclusion: String?
    let workflowId: Int
    let headBranch: String?
    let htmlUrl: URL
    let createdAt: Date
    let updatedAt: Date
    let runStartedAt: Date?
    let actor: WorkflowActor?

    var phase: WorkflowRunPhase { WorkflowRunPhase(status: status, conclusion: conclusion) }
    var glyph: WorkflowStatusKind { WorkflowStatusKind(status: status, conclusion: conclusion) }

    /// Wall time from start to the last update; still growing while the run is active.
    func duration(now: Date = Date()) -> TimeInterval {
        let start = runStartedAt ?? createdAt
        let end = phase == .active ? now : updatedAt
        return max(0, end.timeIntervalSince(start))
    }
}

struct WorkflowStep: Decodable, Hashable, Sendable {
    let name: String
    let status: String
    let conclusion: String?
    let number: Int
    let startedAt: Date?
    let completedAt: Date?

    var glyph: WorkflowStatusKind { WorkflowStatusKind(status: status, conclusion: conclusion) }
}

struct WorkflowJob: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    let htmlUrl: URL?
    let steps: [WorkflowStep]?

    var phase: WorkflowRunPhase { WorkflowRunPhase(status: status, conclusion: conclusion) }
    var glyph: WorkflowStatusKind { WorkflowStatusKind(status: status, conclusion: conclusion) }
    var isCompleted: Bool { status == "completed" }

    func duration(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (completedAt ?? now).timeIntervalSince(startedAt))
    }
}

// MARK: - Status

/// Where a run stands, collapsed to what the pinned chip ranks by.
enum WorkflowRunPhase: Hashable, Sendable {
    /// Ended badly: failure, timed out, or never started.
    case failed
    /// Queued, waiting, in progress, or held for approval.
    case active
    case succeeded
    /// Ended without a verdict: cancelled, skipped, neutral, stale.
    case neutral

    init(status: String?, conclusion: String?) {
        guard status == "completed" else {
            self = .active
            return
        }
        switch conclusion {
        case "success": self = .succeeded
        case "failure", "timed_out", "startup_failure": self = .failed
        // Held for a maintainer's approval — still waiting on something.
        case "action_required": self = .active
        default: self = .neutral
        }
    }
}

/// The glyph a run, job or step wears: finer than `WorkflowRunPhase`, which
/// can't tell queued from running.
enum WorkflowStatusKind: Hashable, Sendable {
    case success, failure, running, queued, neutral

    init(status: String?, conclusion: String?) {
        switch status {
        case "in_progress": self = .running
        case "completed":
            switch WorkflowRunPhase(status: status, conclusion: conclusion) {
            case .succeeded: self = .success
            case .failed: self = .failure
            case .active: self = .queued
            case .neutral: self = .neutral
            }
        default: self = .queued
        }
    }

    var label: String {
        switch self {
        case .success: localized("Succeeded")
        case .failure: localized("Failed")
        case .running: localized("In Progress")
        case .queued: localized("Queued")
        case .neutral: localized("Cancelled or Skipped")
        }
    }
}

enum PinnedWorkflowStatus {
    /// The run the chip shows, from the newest run of each pinned workflow: a
    /// failure first, since a broken pipeline is what the chip exists to say; then
    /// work in flight; then simply the newest. Within each, the most recent wins.
    static func pick(_ latest: [WorkflowRun]) -> WorkflowRun? {
        let newest = latest.sorted { $0.createdAt > $1.createdAt }
        return newest.first { $0.phase == .failed }
            ?? newest.first { $0.phase == .active }
            ?? newest.first
    }
}

/// `1m 12s`, `45s`, `2h 3m` — how GitHub writes a duration.
func workflowDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return localized("\(total)s") }
    if total < 3600 { return localized("\(total / 60)m \(total % 60)s") }
    return localized("\(total / 3600)h \((total % 3600) / 60)m")
}

// MARK: - Client

/// Responses remembered only for their ETag, so a repeated poll can ask GitHub
/// "changed since?" — a `304` costs nothing against the rate limit. Small JSON
/// only (run lists, jobs); logs never pass through here.
actor GitHubConditionalStore {
    static let shared = GitHubConditionalStore()

    private var entries: [URL: (etag: String, body: Data)] = [:]
    private var order: [URL] = []
    private static let capacity = 64

    func entry(for url: URL) -> (etag: String, body: Data)? { entries[url] }

    func store(_ body: Data, etag: String, for url: URL) {
        if entries.updateValue((etag, body), forKey: url) == nil { order.append(url) }
        while order.count > Self.capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    func clear() {
        entries.removeAll()
        order.removeAll()
    }
}

/// GitHub Actions over REST, read only: workflows, runs, jobs, and job logs.
struct GitHubActionsClient: Sendable {
    let connection: GitHubConnection

    func workflows(in slug: String) async throws -> [Workflow] {
        struct Reply: Decodable { let workflows: [Workflow] }
        let reply: Reply = try await get("/repos/\(slug)/actions/workflows", ["per_page": "100"])
        return reply.workflows
    }

    /// The repository's newest runs across every workflow.
    func recentRuns(in slug: String, count: Int = 100) async throws -> [WorkflowRun] {
        struct Reply: Decodable { let workflowRuns: [WorkflowRun] }
        let reply: Reply = try await get(
            "/repos/\(slug)/actions/runs",
            ["per_page": String(count), "exclude_pull_requests": "true"])
        return reply.workflowRuns
    }

    /// One workflow's runs, newest first; `branch` narrows to one branch.
    func runs(
        in slug: String, workflow: Int, branch: String? = nil, page: Int = 1, perPage: Int = 15
    ) async throws -> [WorkflowRun] {
        struct Reply: Decodable { let workflowRuns: [WorkflowRun] }
        var query = [
            "per_page": String(perPage), "page": String(page), "exclude_pull_requests": "true",
        ]
        if let branch { query["branch"] = branch }
        let reply: Reply = try await get("/repos/\(slug)/actions/workflows/\(workflow)/runs", query)
        return reply.workflowRuns
    }

    func run(_ id: Int, in slug: String) async throws -> WorkflowRun {
        try await get("/repos/\(slug)/actions/runs/\(id)", ["exclude_pull_requests": "true"])
    }

    /// The jobs of the run's latest attempt, steps included.
    func jobs(ofRun id: Int, in slug: String) async throws -> [WorkflowJob] {
        struct Reply: Decodable { let jobs: [WorkflowJob] }
        let reply: Reply = try await get(
            "/repos/\(slug)/actions/runs/\(id)/jobs", ["filter": "latest", "per_page": "100"])
        return reply.jobs
    }

    func defaultBranch(of slug: String) async throws -> String {
        struct Reply: Decodable { let defaultBranch: String }
        let reply: Reply = try await get("/repos/\(slug)", [:])
        return reply.defaultBranch
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        guard var components = URLComponents(string: connection.apiBase + path) else {
            throw GitHubIssueProvider.APIError.decoding
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw GitHubIssueProvider.APIError.decoding }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // The URL cache would answer from its own copy and hide the 304 that makes a poll free.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let remembered = await GitHubConditionalStore.shared.entry(for: url)
        if let remembered { request.setValue(remembered.etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let body: Data
        switch http?.statusCode ?? 200 {
        case 304:
            guard let remembered else { throw GitHubIssueProvider.APIError.status(304) }
            body = remembered.body
        case 200...299:
            body = data
            if let etag = http?.value(forHTTPHeaderField: "ETag") {
                await GitHubConditionalStore.shared.store(data, etag: etag, for: url)
            }
        case let code:
            if code == 403 || code == 429,
               http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
                || http?.value(forHTTPHeaderField: "retry-after") != nil {
                throw GitHubIssueProvider.APIError.rateLimited
            }
            throw GitHubIssueProvider.APIError.status(code)
        }
        do {
            return try Self.decoder.decode(T.self, from: body)
        } catch {
            Log.issues.error("Actions decode failed for \(url.path, privacy: .public): \(error, privacy: .public)")
            throw GitHubIssueProvider.APIError.decoding
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Logs

    enum LogError: LocalizedError {
        /// The job hasn't finished: GitHub writes its log only at the end.
        case notReady
        /// Past GitHub's retention, or never written.
        case gone

        var errorDescription: String? {
            switch self {
            case .notReady: localized("The log appears when this job finishes.")
            case .gone: localized("GitHub no longer has this job’s log.")
            }
        }
    }

    /// Where the job's log file lives: GitHub answers with a short-lived signed
    /// URL to blob storage. Asked without following the redirect, so the file
    /// itself is read only as the ranges the view needs.
    func logLocation(ofJob id: Int, in slug: String) async throws -> URL {
        guard let url = URL(string: "\(connection.apiBase)/repos/\(slug)/actions/jobs/\(id)/logs") else {
            throw GitHubIssueProvider.APIError.decoding
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request, delegate: RedirectRefusal.shared)
        guard let http = response as? HTTPURLResponse else { throw GitHubIssueProvider.APIError.decoding }
        switch http.statusCode {
        case 301, 302, 303, 307, 308:
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let blob = URL(string: location)
            else { throw GitHubIssueProvider.APIError.decoding }
            return blob
        case 404: throw LogError.notReady
        case 410: throw LogError.gone
        case let code: throw GitHubIssueProvider.APIError.status(code)
        }
    }

    /// The log file's size in bytes.
    static func logSize(at blob: URL) async throws -> Int {
        var request = URLRequest(url: blob, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubIssueProvider.APIError.decoding }
        if http.statusCode == 404 { throw LogError.notReady }
        guard (200...299).contains(http.statusCode) else { throw GitHubIssueProvider.APIError.status(http.statusCode) }
        return Int(max(0, http.expectedContentLength))
    }

    /// Bytes `range` of the log file. Explicit ranges only: the blob store
    /// ignores a suffix range (`bytes=-N`) and would send the whole file.
    static func logBytes(at blob: URL, range: Range<Int>) async throws -> Data {
        var request = URLRequest(url: blob, timeoutInterval: 30)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubIssueProvider.APIError.decoding }
        switch http.statusCode {
        case 206: return data
        // A server that ignores the range sends the whole file; keep only what was asked.
        case 200: return data.count >= range.upperBound ? data.subdata(in: range) : data
        case 404: throw LogError.notReady
        case let code: throw GitHubIssueProvider.APIError.status(code)
        }
    }
}

/// Stops `URLSession` from following a redirect, so the caller reads the
/// `Location` header instead of downloading what it points at.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectRefusal()

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

// MARK: - Logs

/// One rendered log line.
struct JobLogLine: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case plain
        /// `##[group]` — a section heading, usually the step's `Run …` line.
        case group
        case error
        case warning
        /// `##[command]` — the command a step ran.
        case command
        case debug
    }

    let kind: Kind
    let text: String
}

/// Turns raw job-log text into lines: drops the byte-order mark and each line's
/// timestamp, the terminal escapes, and the workflow-command markers, keeping
/// what they meant as the line's kind.
enum JobLogParser {
    static func lines(_ text: String) -> [JobLogLine] {
        var result: [JobLogLine] = []
        text.enumerateLines { raw, _ in
            if let line = line(raw) { result.append(line) }
        }
        return result
    }

    static func line(_ raw: String) -> JobLogLine? {
        var text = Substring(raw)
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        if text.last == "\r" { text = text.dropLast() }
        text = withoutTimestamp(text)
        var plain = String(text)
        if plain.contains("\u{1B}") { plain = DockerService.stripTerminalEscapes(plain) }
        for (marker, kind) in markers where plain.hasPrefix(marker) {
            if kind == nil { return nil }
            return JobLogLine(kind: kind ?? .plain, text: String(plain.dropFirst(marker.count)))
        }
        return JobLogLine(kind: .plain, text: plain)
    }

    /// `nil` drops the line: `##[endgroup]` closes a heading and says nothing.
    private static let markers: [(String, JobLogLine.Kind?)] = [
        ("##[group]", .group), ("##[endgroup]", nil), ("##[error]", .error),
        ("##[warning]", .warning), ("##[command]", .command), ("##[debug]", .debug),
        ("##[notice]", .plain), ("##[section]", .group),
        // The runner writes the command a step runs with a bare `[command]`.
        ("[command]", .command),
    ]

    /// `2026-10-14T13:35:00.3615979Z ` — checked by shape rather than a regex,
    /// since it runs on every line of a file that can hold hundreds of thousands.
    private static func withoutTimestamp(_ text: Substring) -> Substring {
        let bytes = text.utf8
        guard bytes.count >= 21 else { return text }
        let start = bytes.startIndex
        func byte(_ offset: Int) -> UInt8 { bytes[bytes.index(start, offsetBy: offset)] }
        guard byte(4) == UInt8(ascii: "-"), byte(7) == UInt8(ascii: "-"), byte(10) == UInt8(ascii: "T"),
              byte(13) == UInt8(ascii: ":")
        else { return text }
        var offset = 19
        while offset < min(bytes.count, 40) {
            if byte(offset) == UInt8(ascii: "Z") {
                let next = offset + 1
                guard next < bytes.count, byte(next) == UInt8(ascii: " ") else {
                    return text[text.utf8.index(start, offsetBy: next)...]
                }
                return text[text.utf8.index(start, offsetBy: next + 1)...]
            }
            offset += 1
        }
        return text
    }
}

/// Which bytes of a job log are on screen. Reading starts at the end — where a
/// failure is — and walks back a chunk at a time on request, up to a cap past
/// which the rest stays on GitHub. Pure, so the arithmetic is testable.
struct JobLogWindow: Equatable, Sendable {
    static let chunkSize = 512 * 1024
    static let capacity = 4 * 1024 * 1024

    let size: Int
    /// The first byte loaded; `size` before anything is.
    private(set) var start: Int

    init(size: Int) {
        self.size = size
        start = size
    }

    var loadedBytes: Int { size - start }
    var reachesFileStart: Bool { start == 0 }
    var isAtCapacity: Bool { !reachesFileStart && loadedBytes >= Self.capacity }

    /// The next, earlier chunk to read, or `nil` when there is none to read.
    var nextRange: Range<Int>? {
        guard start > 0, loadedBytes < Self.capacity else { return nil }
        let lower = max(0, start - Self.chunkSize)
        return lower..<start
    }

    mutating func didLoad(_ range: Range<Int>) {
        start = min(start, range.lowerBound)
    }

    /// Splits a chunk that starts mid-file at its first newline: the part before
    /// is the tail of a line whose start is in the next earlier chunk, so it is
    /// held back until that chunk arrives. Cutting at `\n` never splits UTF-8.
    static func splitPartialHead(_ data: Data, atFileStart: Bool) -> (head: Data, body: Data) {
        guard !atFileStart else { return (Data(), data) }
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return (data, Data()) }
        return (data[data.startIndex..<newline], data[data.index(after: newline)...])
    }
}

// MARK: - Pinned workflows

/// What the toolbar's CI chip says: for the project's repository, the run its
/// pinned workflows are judged by (see `PinnedWorkflowStatus.pick`), on the
/// default branch only — the chip answers "is trunk healthy?", not "did some
/// branch fail?".
@MainActor
final class PinnedWorkflowMonitor: ObservableObject {
    struct Status: Equatable {
        let repository: String
        let branch: String
        let run: WorkflowRun
    }

    @Published private(set) var status: Status?

    private var slugs: [String: String] = [:]
    private var defaultBranches: [String: String] = [:]
    private var observer: AnyCancellable?

    init() {
        observer = NotificationCenter.default.publisher(for: GitHubIssueAuth.connectionDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.status = nil
                    self?.defaultBranches.removeAll()
                    Task { await GitHubConditionalStore.shared.clear() }
                }
            }
    }

    /// How long until the next look: soon while the chip shows work in flight,
    /// otherwise once a minute — and every request is ETag-conditional, so an
    /// unchanged answer is free either way.
    var pollInterval: Duration {
        status?.run.phase == .active ? .seconds(15) : .seconds(60)
    }

    /// The repository a checkout's Issues pane reads: the user's pick, else the
    /// leading GitHub remote.
    func repository(for root: String, host: String) async -> String? {
        if let known = slugs[root] { return known }
        let slug: String?
        if let picked = await GitService.issuesRepository(in: root) {
            slug = picked
        } else {
            slug = await GitService.gitHubRemotes(in: root, host: host).first?.slug
        }
        if let slug { slugs[root] = slug }
        return slug
    }

    /// Re-reads the newest default-branch run of every workflow pinned in the
    /// project at `root`. Keeps the last answer on a network failure, so a
    /// dropped request never blanks the chip.
    func refresh(root: String?, settings: AppSettings) async {
        guard let root, settings.githubIntegrationEnabled,
              let connection = GitHubIssueAuth.storedConnection(),
              let slug = await repository(for: root, host: connection.host)
        else {
            status = nil
            return
        }
        let pins = settings.pinnedWorkflowIDs(in: slug)
        guard !pins.isEmpty else {
            status = nil
            return
        }
        let client = GitHubActionsClient(connection: connection)
        do {
            let branch: String
            if let known = defaultBranches[slug] {
                branch = known
            } else {
                branch = try await client.defaultBranch(of: slug)
                defaultBranches[slug] = branch
            }
            let latest = try await withThrowingTaskGroup(of: WorkflowRun?.self) { group in
                for id in pins {
                    group.addTask { try await client.runs(in: slug, workflow: id, branch: branch, perPage: 1).first }
                }
                var runs: [WorkflowRun] = []
                for try await run in group { if let run { runs.append(run) } }
                return runs
            }
            // The pins may have changed while the requests were out.
            guard settings.pinnedWorkflowIDs(in: slug) == pins else { return }
            let next = PinnedWorkflowStatus.pick(latest).map { Status(repository: slug, branch: branch, run: $0) }
            if next != status { status = next }
        } catch GitHubIssueProvider.APIError.status(401) {
            status = nil
        } catch {
            Log.issues.error("pinned workflow refresh for \(slug, privacy: .public) failed: \(error, privacy: .public)")
        }
    }
}

/// The workflow run whose detail is open over the terminal — enough to fetch it
/// and to title it before it arrives.
struct WorkflowRunReference: Hashable, Sendable {
    /// `owner/repo`.
    let repository: String
    let runID: Int
    let title: String
}
