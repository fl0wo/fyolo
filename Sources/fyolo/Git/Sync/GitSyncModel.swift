import AppKit
import Combine
import Foundation

/// The toolbar branch name's uncommitted badge, its pull button, and the git pane's
/// Inspect tab: one model for the selected checkout, owned by the store so the toolbar
/// and the inspector read the same state. The one write is a fast-forward pull the user
/// clicks for — nothing here commits, pushes, merges, or rebases; that stays in the
/// terminal, where the user already works.
///
/// Costs nothing until the toolbar asks: a model nobody has `track`ed runs no git and
/// holds no watch, which is what makes Settings ▸ General's switch a real off switch.
/// Tracking costs one FSEvents stream over the selected repository and one
/// `git status` per settled burst — never per event, never while the app is in the
/// background, never for any repository but the one on screen. The remote is fetched
/// when a repository comes on screen and every few minutes while it stays there, so
/// the pull button appears when there is something to pull — never more than once a
/// minute per repository, and never while the app is in the background.
@MainActor
final class GitSyncModel: ObservableObject {
    @Published private(set) var status: GitSyncStatus?
    @Published private(set) var isFetching = false
    @Published private(set) var isPulling = false
    /// When the tracked repository was last fetched — what "nothing to pull" is only
    /// as good as.
    @Published private(set) var lastFetched: Date?

    /// What a push would send; `nil` with nothing to measure it against.
    @Published private(set) var outgoing: GitSyncRange?
    /// What a pull would bring; `nil` for a branch with no upstream.
    @Published private(set) var incoming: GitSyncRange?
    @Published private(set) var isLoadingRanges = false

    /// Whether the Inspect tab is on screen. Gates the range reads: nobody pays for
    /// a diff of the upstream they are not looking at.
    @Published private(set) var isInspecting = false
    /// Fired when the toolbar asks for a section, so a mounted git pane switches to
    /// Inspect and a mounted Inspect tab scrolls to it.
    let inspectRequests = PassthroughSubject<GitInspectSection, Never>()
    /// The request a pane that was not mounted yet picks up when it appears.
    private var pendingInspect: GitInspectSection?

    private var folder: String?
    private var watcher: FolderEventStream?
    private var refreshDebounce: Task<Void, Never>?
    private var fetchLoop: Task<Void, Never>?
    private var activeObserver: AnyCancellable?
    /// One status read in flight; a request landing mid-read asks for one replay.
    private var refreshing = false
    private var refreshRequested = false
    /// A refresh that arrived while the app was in the background, run on activation.
    private var refreshDeferred = false
    private var trackGeneration = 0
    private var rangeGeneration = 0
    /// What the loaded ranges were read at. Outgoing and incoming only move when HEAD,
    /// the upstream, or the distance between them does — an edit to a working file
    /// changes neither, so it costs the Inspect tab nothing.
    private var loadedRangeKey: RangeKey?
    /// When each repository was last fetched, so moving between projects does not
    /// refetch one that was fetched a minute ago.
    private var fetchTimes: [String: Date] = [:]

    private struct RangeKey: Equatable {
        var head: String?
        var branch: String?
        var upstream: String?
        var publishRemote: String?
        var ahead: Int
        var behind: Int
        /// Bumped by every fetch: a force-pushed upstream can move without the
        /// counts changing.
        var fetch: Date?
    }

    private static let fetchInterval: TimeInterval = 300
    private static let refetchOnActivation: TimeInterval = 60

    /// Points the model at `folder` (any folder inside a repository), or at nothing.
    /// Idempotent for the folder already tracked.
    func track(_ folder: String?) {
        guard folder != self.folder else { return }
        self.folder = folder
        trackGeneration += 1
        let generation = trackGeneration
        watcher = nil
        refreshDebounce?.cancel()
        fetchLoop?.cancel()
        activeObserver = nil
        status = nil
        lastFetched = nil
        clearRanges()
        pendingInspect = nil
        guard let folder else { return }
        Task {
            guard let root = await GitService.topLevel(of: folder),
                  generation == trackGeneration else { return }
            await readStatus(root: root)
            guard generation == trackGeneration, status != nil else { return }
            await arm(root: root, generation: generation)
        }
    }

    // MARK: Status

    private func arm(root: String, generation: Int) async {
        let (tree, gitDirs) = await GitService.watchPaths(for: root)
        guard generation == trackGeneration else { return }
        let paths = [tree] + gitDirs.filter { !$0.hasPrefix(tree + "/") }
        watcher = FolderEventStream(
            paths: paths, latency: 0.4,
            queue: DispatchQueue(label: "sh.fyolo.gitsync.fsevents", qos: .utility)
        ) { [weak self] eventPaths, _ in
            guard eventPaths.contains(where: { !GitPanelModel.isBuildProductEvent($0, underAny: paths) })
            else { return }
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        activeObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.refreshDeferred { self.scheduleRefresh() }
                self.fetchIfStale(olderThan: Self.refetchOnActivation)
            }
        lastFetched = fetchTimes[root]
        if NSApp.isActive { fetchIfStale(olderThan: Self.refetchOnActivation) }
        fetchLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.fetchInterval))
                guard let self, !Task.isCancelled else { return }
                if NSApp.isActive { self.fetchIfStale(olderThan: Self.fetchInterval - 1) }
            }
        }
    }

    /// Coalesces a burst into one read a beat later; parked while the app is in the
    /// background, where nobody is looking at the toolbar.
    private func scheduleRefresh() {
        guard NSApp.isActive else {
            refreshDeferred = true
            return
        }
        refreshDeferred = false
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, let root = self.status?.repositoryRoot else { return }
            await self.readStatus(root: root)
        }
    }

    private func readStatus(root: String) async {
        if refreshing {
            refreshRequested = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        let generation = trackGeneration
        repeat {
            refreshRequested = false
            let read = await GitService.syncStatus(in: root)
            guard generation == trackGeneration else { return }
            if read != status { status = read }
        } while refreshRequested
        await loadRangesIfStale()
    }

    // MARK: Fetch

    private func fetchIfStale(olderThan age: TimeInterval) {
        guard !isFetching, let status, status.upstream != nil || status.publishRemote != nil else { return }
        let root = status.repositoryRoot
        if let last = fetchTimes[root], Date().timeIntervalSince(last) < age { return }
        isFetching = true
        Task {
            let fetched = await GitService.fetch(in: root)
            isFetching = false
            guard self.status?.repositoryRoot == root else { return }
            if fetched {
                let now = Date()
                fetchTimes[root] = now
                lastFetched = now
            } else {
                // Counted as an attempt anyway, so an unreachable remote is retried on
                // the next interval rather than on every activation.
                fetchTimes[root] = Date()
                Log.app.info("git fetch did not complete for \(root, privacy: .public)")
            }
            // The fetch's ref writes arrive as git-dir events too; reading here as well
            // makes the click answer even when FSEvents coalesces them away.
            await readStatus(root: root)
        }
    }

    // MARK: Pull

    /// Fast-forwards the tracked branch to its upstream. A refusal — diverged, or
    /// an uncommitted file in the way — is shown in git's own words, since only the
    /// user can decide how to settle it.
    func pull() {
        guard !isPulling, let status, status.upstream != nil, status.behind > 0 else { return }
        let root = status.repositoryRoot
        isPulling = true
        Task {
            let failure = await GitService.pull(in: root)
            isPulling = false
            if let failure {
                Log.app.info("git pull did not complete for \(root, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = localized("Couldn’t pull \(status.branch ?? status.upstream ?? "")")
                alert.informativeText = failure
                alert.alertStyle = .warning
                alert.runModal()
            }
            guard self.status?.repositoryRoot == root else { return }
            await readStatus(root: root)
        }
    }

    // MARK: Inspect

    /// A toolbar click: point the git pane at Inspect and at `section`.
    func requestInspect(_ section: GitInspectSection) {
        pendingInspect = section
        inspectRequests.send(section)
    }

    /// The request waiting for a pane to show it, without taking it — the git pane
    /// switches to Inspect on it, and the Inspect tab then takes it to scroll.
    var hasPendingInspect: Bool { pendingInspect != nil }

    func consumePendingInspect() -> GitInspectSection? {
        defer { pendingInspect = nil }
        return pendingInspect
    }

    func setInspecting(_ inspecting: Bool) {
        guard inspecting != isInspecting else { return }
        isInspecting = inspecting
        guard inspecting else { return }
        fetchIfStale(olderThan: Self.refetchOnActivation)
        Task { await loadRangesIfStale() }
    }

    private func rangeKey(for status: GitSyncStatus) -> RangeKey {
        RangeKey(head: status.head, branch: status.branch, upstream: status.upstream,
                 publishRemote: status.publishRemote, ahead: status.ahead, behind: status.behind,
                 fetch: lastFetched)
    }

    private func clearRanges() {
        rangeGeneration += 1
        outgoing = nil
        incoming = nil
        loadedRangeKey = nil
        isLoadingRanges = false
    }

    private func loadRangesIfStale() async {
        guard isInspecting, let status else { return }
        let key = rangeKey(for: status)
        guard key != loadedRangeKey else { return }
        rangeGeneration += 1
        let generation = rangeGeneration
        isLoadingRanges = outgoing == nil && incoming == nil
        let root = status.repositoryRoot
        var outgoingBase = status.upstream
        if outgoingBase == nil, status.branch != nil, status.publishRemote != nil {
            outgoingBase = await GitService.compareContext(in: root).suggestedBase
        }
        // A side the counts already say is empty is not worth a diff.
        async let outgoingRead: GitSyncRange? = Self.range(
            .outgoing, base: outgoingBase, known: status.upstream != nil && status.ahead == 0, in: root)
        async let incomingRead: GitSyncRange? = Self.range(
            .incoming, base: status.upstream, known: status.behind == 0, in: root)
        let (loadedOutgoing, loadedIncoming) = await (outgoingRead, incomingRead)
        guard generation == rangeGeneration else { return }
        outgoing = loadedOutgoing
        incoming = loadedIncoming
        loadedRangeKey = key
        isLoadingRanges = false
    }

    private nonisolated static func range(
        _ section: GitInspectSection, base: String?, known empty: Bool, in root: String
    ) async -> GitSyncRange? {
        guard let base else { return nil }
        if empty {
            let range = section == .incoming ? "HEAD...\(base)" : "\(base)...HEAD"
            return .empty(base: base, range: range)
        }
        return await GitService.syncRange(section, against: base, in: root)
    }
}
