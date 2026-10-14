import AppKit
import SwiftUI

// MARK: - Status glyph

/// A run's, job's or step's state as one small mark: filled green or red for a
/// verdict, a turning ring while it runs, an empty ring while it waits, grey
/// for cancelled or skipped. Shared by the Actions list, the run detail and the
/// toolbar chip, so one state reads the same everywhere.
struct WorkflowStatusGlyph: View {
    let kind: WorkflowStatusKind
    var size: CGFloat = 10

    @State private var turning = false

    var body: some View {
        Group {
            switch kind {
            case .success:
                Circle().fill(Color(nsColor: .systemGreen))
            case .failure:
                Circle().fill(Color(nsColor: .systemRed))
            case .running:
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(Color(nsColor: .systemYellow), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(turning ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
                    .onAppear { turning = true }
            case .queued:
                Circle().strokeBorder(Color(nsColor: .systemYellow), lineWidth: 1.5)
            case .neutral:
                Circle().fill(Color.secondary.opacity(0.45))
            }
        }
        .frame(width: size, height: size)
        .help(kind.label)
    }
}

// MARK: - List

/// The Actions list's data for one repository: its workflows, the newest runs
/// across all of them (two requests, both ETag-conditional), and the longer
/// history of whichever workflows are expanded. Held in memory only.
@MainActor
final class ActionsListModel: ObservableObject {
    struct History: Equatable {
        var runs: [WorkflowRun]
        var page: Int
        var hasMore: Bool
        var isLoading: Bool
    }

    let repository: String
    private let client: GitHubActionsClient

    @Published private(set) var workflows: [Workflow] = []
    /// The newest runs by workflow id, newest first, from the repository-wide list.
    @Published private(set) var latestRuns: [Int: [WorkflowRun]] = [:]
    @Published private(set) var histories: [Int: History] = [:]
    @Published var expanded: Set<Int> = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private static let historyPageSize = 15
    /// The last read of each repository, so a remount draws at once and
    /// revalidates behind it.
    private static var cache: [String: (workflows: [Workflow], runs: [WorkflowRun], fetchedAt: Date)] = [:]

    init(repository: String, connection: GitHubConnection) {
        self.repository = repository
        client = GitHubActionsClient(connection: connection)
    }

    /// Any run on screen still queued or running — the list keeps polling only then.
    var hasActiveRuns: Bool {
        latestRuns.values.contains { $0.first?.phase == .active }
            || histories.values.contains { $0.runs.contains { $0.phase == .active } }
    }

    func load(force: Bool) async {
        if let cached = Self.cache[repository] {
            apply(cached.workflows, cached.runs)
            if !force, Date().timeIntervalSince(cached.fetchedAt) < 30 { return }
        } else {
            isLoading = true
        }
        defer { isLoading = false }
        do {
            async let workflows = client.workflows(in: repository)
            async let runs = client.recentRuns(in: repository)
            let (fetchedWorkflows, fetchedRuns) = try await (workflows, runs)
            Self.cache[repository] = (fetchedWorkflows, fetchedRuns, Date())
            apply(fetchedWorkflows, fetchedRuns)
            errorMessage = nil
            for id in expanded { await loadHistory(id, page: 1) }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func apply(_ workflows: [Workflow], _ runs: [WorkflowRun]) {
        let active = workflows.filter(\.isActive)
        if active != self.workflows { self.workflows = active }
        let grouped = Dictionary(grouping: runs, by: \.workflowId)
            .mapValues { $0.sorted { $0.createdAt > $1.createdAt } }
        if grouped != latestRuns { latestRuns = grouped }
    }

    func toggle(_ workflow: Workflow) {
        if expanded.remove(workflow.id) == nil {
            expanded.insert(workflow.id)
            Task { await loadHistory(workflow.id, page: 1) }
        }
    }

    func loadMore(_ workflow: Workflow) {
        guard let history = histories[workflow.id], history.hasMore, !history.isLoading else { return }
        Task { await loadHistory(workflow.id, page: history.page + 1) }
    }

    private func loadHistory(_ id: Int, page: Int) async {
        var history = histories[id] ?? History(runs: latestRuns[id] ?? [], page: 0, hasMore: true, isLoading: false)
        history.isLoading = true
        histories[id] = history
        do {
            let runs = try await client.runs(in: repository, workflow: id, page: page, perPage: Self.historyPageSize)
            history.runs = page == 1 ? runs : history.runs + runs.filter { run in !history.runs.contains { $0.id == run.id } }
            history.page = page
            history.hasMore = runs.count == Self.historyPageSize
        } catch {
            Log.issues.error("workflow history for \(id) failed: \(error, privacy: .public)")
        }
        history.isLoading = false
        histories[id] = history
    }

    /// The runs a row shows when expanded: its fetched history, else what the
    /// repository-wide list already had.
    func runs(of workflow: Workflow) -> [WorkflowRun] {
        histories[workflow.id]?.runs ?? latestRuns[workflow.id] ?? []
    }

    /// Pinned workflows in the order they were pinned, then the rest by their
    /// newest run, then those that never ran, by name.
    func ordered(pinned: [Int], search: String) -> (pinned: [Workflow], others: [Workflow]) {
        let matching = workflows.filter { workflow in
            search.split(whereSeparator: \.isWhitespace).allSatisfy { workflow.name.localizedStandardContains($0) }
        }
        let pinnedSet = Set(pinned)
        let pinnedRows = pinned.compactMap { id in matching.first { $0.id == id } }
        let others = matching.filter { !pinnedSet.contains($0.id) }.sorted { left, right in
            switch (latestRuns[left.id]?.first?.createdAt, latestRuns[right.id]?.first?.createdAt) {
            case let (l?, r?): return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
        return (pinnedRows, others)
    }

    static func message(for error: Error) -> String {
        switch error {
        case GitHubIssueProvider.APIError.status(401):
            return localized("GitHub rejected the token. Reconnect from the Issues tab.")
        case GitHubIssueProvider.APIError.status(403):
            return localized("This GitHub sign-in can’t read Actions in this repository.")
        case GitHubIssueProvider.APIError.status(404):
            return localized("GitHub Actions isn’t available for this repository.")
        default:
            return error.localizedDescription
        }
    }
}

/// The Issues pane's Actions segment: every active workflow with a strip of its
/// latest outcomes, pinned ones first. A workflow expands into its run history;
/// a run opens over the terminal with its jobs and logs.
struct ActionsListView: View {
    @EnvironmentObject var store: FyoloStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let searchText: String
    let refreshToken: Int
    @StateObject private var model: ActionsListModel

    /// Often enough to watch a run go green; every poll is a conditional request,
    /// and it only runs while something listed is queued or running.
    private static let activePollInterval: Duration = .seconds(10)

    init(repository: String, connection: GitHubConnection, searchText: String, refreshToken: Int) {
        self.searchText = searchText
        self.refreshToken = refreshToken
        _model = StateObject(wrappedValue: ActionsListModel(repository: repository, connection: connection))
    }

    private var pins: [Int] { settings.pinnedWorkflowIDs(in: model.repository) }

    var body: some View {
        content
            .task {
                await model.load(force: false)
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.activePollInterval)
                    if model.hasActiveRuns, NSApp.isActive { await model.load(force: true) }
                }
            }
            .onChange(of: refreshToken) { Task { await model.load(force: true) } }
    }

    @ViewBuilder
    private var content: some View {
        let sections = model.ordered(pinned: pins, search: searchText)
        if model.isLoading, model.workflows.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.workflows.isEmpty {
            PaneEmptyState(localized("Couldn’t load"), icon: .github, message: error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.workflows.isEmpty {
            PaneEmptyState(
                localized("No Workflows"), icon: .github,
                message: localized("This repository has no active GitHub Actions workflows."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.pinned.isEmpty, sections.others.isEmpty {
            PaneEmptyState(localized("No Matches"), icon: .search)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section(localized("Pinned"), sections.pinned, pinned: true)
                    section(localized("Workflows"), sections.others, pinned: false)
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ workflows: [Workflow], pinned: Bool) -> some View {
        if !workflows.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(workflows) { workflow in
                WorkflowRow(
                    workflow: workflow,
                    latest: model.latestRuns[workflow.id] ?? [],
                    isPinned: pinned,
                    isExpanded: model.expanded.contains(workflow.id),
                    font: settings.interfaceFont,
                    chrome: settings.chromeTheme(for: colorScheme),
                    toggle: { model.toggle(workflow) },
                    setPinned: { settings.setWorkflow(workflow.id, pinned: $0, in: model.repository) }
                )
                if model.expanded.contains(workflow.id) {
                    history(of: workflow)
                }
            }
        }
    }

    @ViewBuilder
    private func history(of workflow: Workflow) -> some View {
        let runs = model.runs(of: workflow)
        let state = model.histories[workflow.id]
        if runs.isEmpty {
            Text(state?.isLoading == true ? localized("Loading…") : localized("No runs yet."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 40)
                .padding(.vertical, 4)
        }
        ForEach(runs) { run in
            WorkflowRunRow(
                run: run,
                isSelected: store.openWorkflowRun?.runID == run.id,
                chrome: settings.chromeTheme(for: colorScheme)
            ) {
                store.openWorkflowRun = WorkflowRunReference(
                    repository: model.repository, runID: run.id,
                    title: "\(run.name ?? workflow.name) #\(run.runNumber)")
            }
        }
        if state?.hasMore == true, !runs.isEmpty {
            Button(state?.isLoading == true ? localized("Loading…") : localized("Show More")) {
                model.loadMore(workflow)
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .disabled(state?.isLoading == true)
            .padding(.leading, 40)
            .padding(.vertical, 4)
        }
    }
}

/// One workflow: its newest outcome, its name, a strip of its last runs (oldest
/// left, so the newest sits beside the age), and a pin that shows on hover and
/// stays once set.
private struct WorkflowRow: View {
    let workflow: Workflow
    let latest: [WorkflowRun]
    let isPinned: Bool
    let isExpanded: Bool
    let font: Font
    let chrome: ChromeTheme?
    let toggle: () -> Void
    let setPinned: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            WorkflowStatusGlyph(kind: latest.first?.glyph ?? .neutral)
            Text(workflow.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                ForEach(latest.prefix(8).reversed()) { run in
                    WorkflowStatusGlyph(kind: run.glyph, size: 6)
                }
            }
            if let newest = latest.first {
                Text(newest.createdAt.issueRowAge)
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Button { setPinned(!isPinned) } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isPinned || isHovering ? 1 : 0)
            .help(isPinned ? localized("Unpin") : localized("Pin to the top and the toolbar"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(SidebarRowHighlight(isSelected: false, isHovering: isHovering, chrome: chrome))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button(isPinned ? localized("Unpin") : localized("Pin")) { setPinned(!isPinned) }
            if let url = workflow.htmlUrl {
                Divider()
                Button(localized("Open in Browser")) { NSWorkspace.shared.open(url) }
                Button(localized("Copy Link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
        .help(workflow.path)
    }
}

/// One run in an expanded workflow: outcome, title, branch, number, how long it took.
private struct WorkflowRunRow: View {
    let run: WorkflowRun
    let isSelected: Bool
    let chrome: ChromeTheme?
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            WorkflowStatusGlyph(kind: run.glyph, size: 8)
            Text(run.displayTitle ?? run.name ?? "#\(run.runNumber)")
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if let branch = run.headBranch {
                Text(branch)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            Text("#\(run.runNumber)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
            Text(workflowDuration(run.duration()))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.leading, 40)
        .padding(.trailing, 12)
        .padding(.vertical, 3.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering, chrome: chrome))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button(localized("Open in Browser")) { NSWorkspace.shared.open(run.htmlUrl) }
            Button(localized("Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.htmlUrl.absoluteString, forType: .string)
            }
        }
        .help("\(run.glyph.label) · \(run.event) · \(run.actor?.login ?? "")")
    }
}

// MARK: - Run detail

/// One run's jobs, and the log of the job on screen. The log is read as byte
/// ranges from its end, never whole, and lives only as long as this model: no
/// cache, nothing on disk.
@MainActor
final class WorkflowRunDetailModel: ObservableObject {
    enum LogState: Equatable {
        case idle
        case notReady
        case loading
        case loaded
        case failed(String)
    }

    let reference: WorkflowRunReference

    @Published private(set) var run: WorkflowRun?
    @Published private(set) var jobs: [WorkflowJob] = []
    @Published private(set) var errorMessage: String?
    @Published var selectedJobID: Int? {
        didSet { if selectedJobID != oldValue { loadLog() } }
    }

    @Published private(set) var logState: LogState = .idle
    @Published private(set) var lines: [JobLogLine] = []
    @Published private(set) var window: JobLogWindow?
    @Published private(set) var isLoadingEarlier = false
    /// Bumped on every change to `lines`; `prepended` says how many arrived at the top.
    @Published private(set) var logRevision = 0
    private(set) var prepended = 0

    private var blob: URL?
    /// The start of the earliest loaded chunk's first line, whose beginning is in
    /// the chunk before it — held until that chunk arrives.
    private var pendingHead = Data()
    private var logTask: Task<Void, Never>?

    init(reference: WorkflowRunReference) {
        self.reference = reference
    }

    private var client: GitHubActionsClient? {
        GitHubIssueAuth.storedConnection().map(GitHubActionsClient.init)
    }

    var selectedJob: WorkflowJob? { jobs.first { $0.id == selectedJobID } }

    /// Still worth polling: the run, or one of its jobs, hasn't finished.
    var isActive: Bool {
        run.map { $0.phase == .active } ?? true || jobs.contains { !$0.isCompleted }
    }

    var errorLines: [(index: Int, line: JobLogLine)] {
        lines.enumerated().filter { $0.element.kind == .error }.map { ($0.offset, $0.element) }
    }

    func refresh() async {
        guard let client else {
            errorMessage = localized("Connect GitHub from the Issues tab to see this run.")
            return
        }
        do {
            async let run = client.run(reference.runID, in: reference.repository)
            async let jobs = client.jobs(ofRun: reference.runID, in: reference.repository)
            let (fetchedRun, fetchedJobs) = try await (run, jobs)
            let previous = selectedJob
            if fetchedRun != self.run { self.run = fetchedRun }
            if fetchedJobs != self.jobs { self.jobs = fetchedJobs }
            errorMessage = nil
            if selectedJobID == nil || !fetchedJobs.contains(where: { $0.id == selectedJobID }) {
                selectedJobID = Self.initialJob(in: fetchedJobs)?.id
            } else if let previous, !previous.isCompleted, selectedJob?.isCompleted == true {
                // The job on screen just finished: its log exists now.
                loadLog()
            }
        } catch {
            errorMessage = ActionsListModel.message(for: error)
        }
    }

    /// Where the detail opens: the first failed job, else the first running one,
    /// else the last — the part of a run someone opening it most likely wants.
    static func initialJob(in jobs: [WorkflowJob]) -> WorkflowJob? {
        jobs.first { $0.phase == .failed }
            ?? jobs.first { $0.status == "in_progress" }
            ?? jobs.last
    }

    private func loadLog() {
        logTask?.cancel()
        lines = []
        window = nil
        blob = nil
        pendingHead = Data()
        prepended = 0
        logRevision += 1
        guard let job = selectedJob, let client else {
            logState = .idle
            return
        }
        guard job.isCompleted else {
            logState = .notReady
            return
        }
        logState = .loading
        let repository = reference.repository
        logTask = Task {
            do {
                let blob = try await client.logLocation(ofJob: job.id, in: repository)
                let size = try await GitHubActionsClient.logSize(at: blob)
                var window = JobLogWindow(size: size)
                var parsed: [JobLogLine] = []
                if let range = window.nextRange {
                    let data = try await GitHubActionsClient.logBytes(at: blob, range: range)
                    try Task.checkCancellation()
                    let split = JobLogWindow.splitPartialHead(data, atFileStart: range.lowerBound == 0)
                    pendingHead = Data(split.head)
                    parsed = await Self.parse(Data(split.body))
                    window.didLoad(range)
                }
                try Task.checkCancellation()
                self.blob = blob
                self.window = window
                lines = parsed
                prepended = 0
                logRevision += 1
                logState = .loaded
            } catch is CancellationError {
                return
            } catch let error as GitHubActionsClient.LogError where error == .notReady {
                logState = .notReady
            } catch {
                guard !Task.isCancelled else { return }
                logState = .failed(error.localizedDescription)
            }
        }
    }

    /// Reads the chunk before what's on screen, joining the line it split.
    func loadEarlier() {
        guard var window, let range = window.nextRange, let blob, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        let jobID = selectedJobID
        Task {
            defer { isLoadingEarlier = false }
            do {
                let data = try await GitHubActionsClient.logBytes(at: blob, range: range)
                guard selectedJobID == jobID else { return }
                let split = JobLogWindow.splitPartialHead(data + pendingHead, atFileStart: range.lowerBound == 0)
                pendingHead = Data(split.head)
                let earlier = await Self.parse(Data(split.body))
                window.didLoad(range)
                self.window = window
                prepended = earlier.count
                lines = earlier + lines
                logRevision += 1
            } catch {
                // The signed URL is short-lived; an expired one means reading it again from the top.
                Log.issues.error("earlier log chunk failed: \(error, privacy: .public)")
                loadLog()
            }
        }
    }

    /// Parsing a chunk is off the main actor: a 512 KiB chunk is thousands of lines.
    private static func parse(_ data: Data) async -> [JobLogLine] {
        await Task.detached(priority: .userInitiated) {
            JobLogParser.lines(String(decoding: data, as: UTF8.self))
        }.value
    }

    func cancel() {
        logTask?.cancel()
    }
}

extension GitHubActionsClient.LogError: Equatable {}

/// The run detail, over the terminal like an issue or PR: a header naming the
/// run, the jobs down the left, and the selected job's steps above its log.
struct WorkflowRunDetailView: View {
    let reference: WorkflowRunReference
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void

    @StateObject private var model: WorkflowRunDetailModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var revealLine: Int?
    @State private var showsSteps = true

    /// While a run is in flight its jobs and steps move every few seconds.
    private static let pollInterval: Duration = .seconds(5)
    private static let sideBySideMinWidth: CGFloat = 520

    init(reference: WorkflowRunReference, settings: AppSettings, onClose: @escaping () -> Void) {
        self.reference = reference
        self.settings = settings
        self.onClose = onClose
        _model = StateObject(wrappedValue: WorkflowRunDetailModel(reference: reference))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if let error = model.errorMessage, model.run == nil {
                PaneEmptyState(localized("Couldn’t load"), icon: .github, message: error)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.run == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= Self.sideBySideMinWidth {
                        HStack(spacing: 0) {
                            jobRail
                                .frame(width: min(260, max(180, geometry.size.width * 0.28)))
                            Divider().opacity(0.5)
                            jobContent
                        }
                    } else {
                        VStack(spacing: 0) {
                            jobPicker
                            jobContent
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .task {
            await model.refresh()
            while !Task.isCancelled, model.isActive {
                try? await Task.sleep(for: Self.pollInterval)
                if NSApp.isActive { await model.refresh() }
            }
        }
        .onDisappear { model.cancel() }
        .onExitCommand(perform: onClose)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            WorkflowStatusGlyph(kind: model.run?.glyph ?? .queued, size: 11)
                .frame(width: 15)
            Text(model.run.map { "\($0.name ?? "") #\($0.runNumber)" } ?? reference.title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Text(model.run?.displayTitle ?? "")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let run = model.run {
                Text(summary(of: run))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                TreeHeaderButton(huge: .squareArrowUpRight, help: localized("Open on GitHub")) {
                    NSWorkspace.shared.open(run.htmlUrl)
                }
            }
            InspectorDetailChromeButtons()
        }
        .padding(.horizontal, 8)
        .frame(height: GitChangesView.topBarHeight)
        .modifier(DetailHeaderTitlebarInset())
    }

    private func summary(of run: WorkflowRun) -> String {
        var parts: [String] = []
        if let branch = run.headBranch { parts.append(branch) }
        parts.append(run.event)
        if let actor = run.actor?.login { parts.append(actor) }
        parts.append(run.createdAt.issueRowAge)
        parts.append(workflowDuration(run.duration()))
        return parts.joined(separator: " · ")
    }

    // MARK: Jobs

    private var jobRail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                Text(localized("Jobs").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                ForEach(model.jobs) { job in
                    JobRow(job: job, isSelected: job.id == model.selectedJobID,
                           chrome: settings.chromeTheme(for: colorScheme)) {
                        model.selectedJobID = job.id
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var jobPicker: some View {
        HStack {
            Picker(localized("Job"), selection: Binding(
                get: { model.selectedJobID ?? 0 },
                set: { model.selectedJobID = $0 }
            )) {
                ForEach(model.jobs) { job in
                    Text(job.name).tag(job.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var jobContent: some View {
        if let job = model.selectedJob {
            VStack(spacing: 0) {
                steps(of: job)
                logBar(for: job)
                Divider().opacity(0.4)
                log(for: job)
            }
        } else {
            PaneEmptyState(localized("No Jobs"), icon: .listBullet,
                           message: localized("This run hasn’t started any jobs yet."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func steps(of job: WorkflowJob) -> some View {
        if let steps = job.steps, !steps.isEmpty {
            DisclosureGroup(isExpanded: $showsSteps) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(steps, id: \.number) { step in
                            HStack(spacing: 7) {
                                WorkflowStatusGlyph(kind: step.glyph, size: 8)
                                Text(step.name)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(step.glyph == .failure ? Color(nsColor: .systemRed) : .primary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if let started = step.startedAt {
                                    Text(workflowDuration((step.completedAt ?? Date()).timeIntervalSince(started)))
                                        .font(.system(size: 9.5).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxHeight: 170)
            } label: {
                Text(localized("Steps (\(steps.count))").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func logBar(for job: WorkflowJob) -> some View {
        HStack(spacing: 10) {
            Text(logExtent)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if model.window?.nextRange != nil {
                Button(model.isLoadingEarlier ? localized("Loading…") : localized("Load Earlier")) {
                    model.loadEarlier()
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .disabled(model.isLoadingEarlier)
            } else if model.window?.isAtCapacity == true {
                Text(localized("The rest is on GitHub."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            let errors = model.errorLines
            if !errors.isEmpty {
                Menu {
                    ForEach(errors.prefix(50), id: \.index) { error in
                        Button(String(error.line.text.prefix(90))) { revealLine = error.index }
                    }
                } label: {
                    Text(localized("Errors (\(errors.count))"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let url = job.htmlUrl {
                TreeHeaderButton(huge: .squareArrowUpRight, help: localized("Open This Job on GitHub")) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var logExtent: String {
        guard let window = model.window else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let total = formatter.string(fromByteCount: Int64(window.size))
        if window.reachesFileStart { return localized("Full log · \(total)") }
        let loaded = formatter.string(fromByteCount: Int64(window.loadedBytes))
        return localized("Last \(loaded) of \(total)")
    }

    @ViewBuilder
    private func log(for job: WorkflowJob) -> some View {
        switch model.logState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notReady:
            PaneEmptyState(
                localized("Still Running"), icon: .clock,
                message: GitHubActionsClient.LogError.notReady.errorDescription)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            PaneEmptyState(localized("Couldn’t load"), icon: .github, message: message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            JobLogTextView(
                lines: model.lines, revision: model.logRevision, prepended: model.prepended,
                revealLine: $revealLine)
        }
    }
}

private struct JobRow: View {
    let job: WorkflowJob
    let isSelected: Bool
    let chrome: ChromeTheme?
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            WorkflowStatusGlyph(kind: job.glyph, size: 9)
            Text(job.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let duration = job.duration() {
                Text(workflowDuration(duration))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering, chrome: chrome))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: select)
        .help(job.name)
    }
}

// MARK: - Log text

/// The job log in a read-only text view: monospace, selectable, ⌘F through the
/// system find bar. Built from parsed lines — headings bold, errors red,
/// warnings orange — and rebuilt only when the lines change.
struct JobLogTextView: NSViewRepresentable {
    let lines: [JobLogLine]
    let revision: Int
    /// How many of `lines` were just added at the top, to hold the reader's place.
    let prepended: Int
    @Binding var revealLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage
        else { return }
        let coordinator = context.coordinator
        if coordinator.revision != revision {
            let firstRun = coordinator.revision == nil
            let topLine = firstRun ? nil : coordinator.visibleTopLine(in: textView)
            coordinator.revision = revision
            let built = Coordinator.build(lines)
            coordinator.lineStarts = built.starts
            storage.setAttributedString(built.text)
            if prepended > 0, let topLine {
                coordinator.scroll(to: topLine + prepended, in: textView, highlight: false)
            } else {
                // A log is read from its end, where a failure is.
                textView.scrollToEndOfDocument(nil)
            }
        }
        if let line = revealLine {
            coordinator.scroll(to: line, in: textView, highlight: true)
            DispatchQueue.main.async { revealLine = nil }
        }
    }

    @MainActor
    final class Coordinator {
        var revision: Int?
        var lineStarts: [Int] = []

        static func build(_ lines: [JobLogLine]) -> (text: NSAttributedString, starts: [Int]) {
            let regular = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            let text = NSMutableAttributedString()
            var starts: [Int] = []
            starts.reserveCapacity(lines.count)
            for line in lines {
                starts.append(text.length)
                var attributes: [NSAttributedString.Key: Any] = [.font: regular, .foregroundColor: NSColor.textColor]
                switch line.kind {
                case .plain: break
                case .group: attributes[.font] = bold
                case .error: attributes[.foregroundColor] = NSColor.systemRed
                case .warning: attributes[.foregroundColor] = NSColor.systemOrange
                case .command: attributes[.foregroundColor] = NSColor.systemBlue
                case .debug: attributes[.foregroundColor] = NSColor.tertiaryLabelColor
                }
                text.append(NSAttributedString(string: line.text + "\n", attributes: attributes))
            }
            return (text, starts)
        }

        func visibleTopLine(in textView: NSTextView) -> Int? {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
            let visible = textView.visibleRect
            let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: visible.minY), in: container)
            let character = layoutManager.characterIndexForGlyph(at: glyph)
            return lineIndex(containing: character)
        }

        func scroll(to line: Int, in textView: NSTextView, highlight: Bool) {
            guard lineStarts.indices.contains(line) else { return }
            let start = lineStarts[line]
            let end = lineStarts.indices.contains(line + 1) ? lineStarts[line + 1] - 1 : (textView.string as NSString).length
            let range = NSRange(location: start, length: max(0, end - start))
            textView.scrollRangeToVisible(range)
            if highlight {
                textView.setSelectedRange(range)
                textView.showFindIndicator(for: range)
            }
        }

        private func lineIndex(containing character: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= character { low = middle } else { high = middle - 1 }
            }
            return max(0, low)
        }
    }
}

// MARK: - Toolbar chip

/// The toolbar's CI chip, left of the run capsule: the run the project's pinned
/// workflows are judged by on the default branch, as its status and workflow
/// name. Clicking it opens that run. Absent until something is pinned.
struct PinnedWorkflowChip: View {
    @EnvironmentObject var store: FyoloStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var monitor: PinnedWorkflowMonitor

    @Environment(\.controlActiveState) private var controlActive

    private static let maximumNameWidth: CGFloat = 150

    /// What the chip's polling depends on; a change restarts it at once.
    private var pollKey: String {
        "\(store.runCapsuleRoot ?? "")|\(settings.githubIntegrationEnabled)|\(settings.pinnedWorkflows)"
    }

    var body: some View {
        HStack(spacing: 0) {
            // A view that draws nothing never starts its `.task`, and with no pins
            // yet there is nothing to draw — this keeps the polling alive.
            Color.clear.frame(width: 0, height: 0)
            if let status = monitor.status {
                chip(status)
            }
        }
        .task(id: pollKey) {
            while !Task.isCancelled {
                if NSApp.isActive { await monitor.refresh(root: store.runCapsuleRoot, settings: settings) }
                try? await Task.sleep(for: monitor.pollInterval)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await monitor.refresh(root: store.runCapsuleRoot, settings: settings) }
        }
    }

    private func chip(_ status: PinnedWorkflowMonitor.Status) -> some View {
        let name = status.run.name ?? localized("Workflow")
        return Button {
            store.showWorkflowRun(WorkflowRunReference(
                repository: status.repository, runID: status.run.id,
                title: "\(name) #\(status.run.runNumber)"))
        } label: {
            HStack(spacing: 7) {
                WorkflowStatusGlyph(kind: status.run.glyph, size: 9)
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(controlActive == .inactive
                                     ? Color(nsColor: .disabledControlTextColor) : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Self.maximumNameWidth)
            }
            .padding(.horizontal, 14)
            .frame(height: InspectorTabsToolbar.controlHeight)
            .background { ToolbarCapsuleChrome() }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(localized("\(name) · \(status.run.glyph.label) on \(status.branch) · \(status.run.createdAt.issueRowAge) ago"))
    }
}
