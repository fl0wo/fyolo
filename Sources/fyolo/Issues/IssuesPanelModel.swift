import Foundation
import AppKit

// MARK: - Issues pane state

/// State for the Issues pane, per repo root (recreated by `.id(repoRoot)` like
/// `GitPanelModel`): the GitHub connection, the container binding resolved from
/// the checkout's remotes, the list, and the pushed-in detail.
@MainActor
final class IssuesPanelModel: ObservableObject {
    /// Where the pane is in the connect → bind → read ladder; each step has a
    /// zero state except `.ready`.
    enum Phase: Equatable {
        /// No token — show Connect.
        case disconnected
        /// Device flow underway: show the code, wait for approval in the browser.
        case connecting(userCode: String)
        /// Connected, but none of the project's remotes is a github.com repo.
        case unbound
        case ready

        var userCode: String? {
            if case .connecting(let userCode) = self { return userCode }
            return nil
        }
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var container: IssueContainer?
    @Published private(set) var items: [IssueSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// How the user can recover from a failed load, so the error state offers the *right* action.
    /// `reauthorize` (the reconnect / grant-org path) is reserved for a genuine access 403 — a
    /// valid token with no rights to this repo. Everything else (rate limits, 404, 5xx, network,
    /// decode) is `retry`, since reconnecting can't fix it. `nil` when there's no error.
    enum Recovery { case reauthorize, retry }
    @Published private(set) var recovery: Recovery?
    /// The pushed-in detail (list → detail, like git pane file → diff).
    @Published var openItem: IssueSummary?
    @Published private(set) var detail: IssueDetail?
    @Published private(set) var detailError: String?

    @Published var query = IssueQuery() {
        didSet {
            // A rebind rewrites the query as part of clearing the old repository out;
            // it issues its own load, so this must not queue a second one against a
            // container that is still being settled.
            guard query != oldValue, !isRebinding else { return }
            Task { await loadList() }
        }
    }

    private var isRebinding = false

    let repoRoot: String
    private var provider: GitHubIssueProvider?

    /// The app-level cache (keyed by remote identity), injected by the store on register so the
    /// fetched list + detail outlive this — inherently transient — model instance. See `IssueCache`
    /// and `FyoloStore.registerIssuesModel`.
    private var cache: IssueCache?
    func attachCache(_ cache: IssueCache) { self.cache = cache }

    init(repoRoot: String) {
        self.repoRoot = repoRoot
    }

    var capabilities: IssueCapabilities? { provider?.capabilities }

    /// Whether the one-time resolve-and-load has run for this model. The model is registered on
    /// the store (see `FyoloStore.registerIssuesModel`), whose `.task` re-fires on every remount
    /// — so the initial git resolve + list pull must run once, not on each maximize toggle.
    private var didStart = false

    /// Entry point on appear: restore the Keychain token, resolve the binding
    /// from the checkout's remotes, and load.
    func start() async {
        await ensureReady()
        guard provider != nil else {
            phase = .disconnected
            return
        }
        guard !didStart else { return }
        didStart = true
        await loadList()
    }

    /// Coalesced one-time getters for the token + binding, so a freshly-created model (a session
    /// switch remounts `IssuesView` with an empty one) is usable the moment *any* caller needs it
    /// — `loadDetail` in particular, which must reach the container to form its cache key. The
    /// `Task` handle dedupes a concurrent `start()` + `loadDetail` into a single git resolve.
    private var readyTask: Task<Void, Never>?
    /// Whether the binding has been resolved once. Gates on this rather than `container == nil`, so
    /// an *unbound* repo (no github.com remote leaves `container` nil) resolves once, not on every
    /// `loadDetail`. Reset by `disconnect()` so a reconnect re-resolves.
    private var didResolveContainer = false
    private func ensureReady() async {
        if provider == nil, let token = GitHubIssueAuth.storedToken() {
            provider = GitHubIssueProvider(token: token)
        }
        guard provider != nil, !didResolveContainer else { return }
        if let readyTask { return await readyTask.value }
        let task = Task { await resolveContainer() }
        readyTask = task
        await task.value
        readyTask = nil
    }

    // MARK: Connect / disconnect

    /// Runs the whole device flow: shows the code, opens the verification page,
    /// polls until approved, then loads the pane.
    func connect() async {
        errorMessage = nil
        recovery = nil
        do {
            let token = try await GitHubIssueAuth.connect { phase = .connecting(userCode: $0) }
            provider = GitHubIssueProvider(token: token)
            didStart = true
            await resolveContainer()
            await loadList()
        } catch {
            phase = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        GitHubIssueAuth.deleteToken()
        provider = nil
        items = []
        candidates = []
        openItem = nil
        detail = nil
        // The token is gone, so a later reconnect (possibly a different account) must not read
        // this account's cached private-repo detail.
        cache?.clear()
        didStart = false
        // Re-resolve the binding on the next reconnect (possibly a different account/repo).
        didResolveContainer = false
        readyTask = nil
        phase = .disconnected
        errorMessage = nil
        recovery = nil
    }

    /// Recover from a non-401 failure (typically a 403: the token is valid but has
    /// no rights to *this* repo). A 401 self-heals via `disconnect()` in `loadList`,
    /// but a 403 leaves the pane bound-yet-empty with no way out — so drop the token
    /// and re-run the device flow, letting the user approve under a different account
    /// (or after granting fyolo org access, see `openConnectionSettings`).
    func reconnect() async {
        disconnect()
        await connect()
    }

    /// Opens the OAuth app's connections page, where the user grants fyolo access
    /// to the org that owns a private repo — the fix a bare reconnect can't make,
    /// since GitHub re-issues the same token without re-prompting for org grants.
    func openConnectionSettings() {
        NSWorkspace.shared.open(GitHubIssueAuth.settingsURL)
    }

    // MARK: Loading

    /// Every repository this checkout could show a tracker for, in menu order. One
    /// entry is the overwhelmingly common case and the pane stays silent about it;
    /// more than one means a fork, and the top bar offers the choice.
    @Published private(set) var candidates: [IssueRepositoryCandidate] = []

    /// Fork parents already looked up this launch, keyed by the probed slug — a
    /// `Set` of slugs probed plus the answers, so "not a fork" is remembered too.
    /// The model is per-pane and short-lived (a session switch builds a new one),
    /// so without this the probe would repeat on every remount.
    private static var probedForForkParent: Set<String> = []
    private static var forkParents: [String: String] = [:]

    /// What the ladder chose, and the full menu it chose from.
    struct Binding: Equatable {
        let selected: IssueRepositoryCandidate
        let candidates: [IssueRepositoryCandidate]
    }

    /// The ladder itself, from most to least authoritative: the user's own pick,
    /// then an `upstream` remote, then the fork parent GitHub reports for the
    /// leading remote, then that remote. Pure, so the precedence can be pinned
    /// down in tests without a window, a checkout, or the network; the caller
    /// gathers the inputs and only pays for `forkParent` when the rungs above it
    /// miss. `nil` when there is nothing at all to bind to.
    static func resolveBinding(
        remotes: [IssueRepositoryCandidate],
        pick: String?,
        forkParent: (String) async -> String?
    ) async -> Binding? {
        var found = remotes

        /// Binds `slug`, adding it to the menu when no remote already offers it —
        /// which is how a repository the checkout never names (a fork parent, or a
        /// pick whose remote is gone) still becomes switchable rather than a
        /// one-entry menu the pane hides.
        func bind(_ slug: String) -> Binding {
            if let match = found.first(where: { $0.slug == slug }) {
                return Binding(selected: match, candidates: found)
            }
            let added = IssueRepositoryCandidate(slug: slug, remoteName: nil)
            found.append(added)
            return Binding(selected: added, candidates: found)
        }

        // Before the empty check: an explicit pick outlives the remote it came from,
        // so renaming or dropping a remote can't silently drag the pane back to a
        // repository the user already rejected.
        if let pick { return bind(pick) }
        guard let leading = found.first else { return nil }
        if let upstream = found.first(where: { $0.remoteName == "upstream" }) {
            return Binding(selected: upstream, candidates: found)
        }
        if let parent = await forkParent(leading.slug) { return bind(parent) }
        return Binding(selected: leading, candidates: found)
    }

    private func resolveContainer() async {
        let remotes = await GitService.gitHubRemotes(in: repoRoot).map {
            IssueRepositoryCandidate(slug: $0.slug, remoteName: $0.name)
        }
        let pick = await GitService.issuesRepository(in: repoRoot)
        let binding = await Self.resolveBinding(
            remotes: remotes, pick: pick, forkParent: { await self.forkParent(of: $0) })
        didResolveContainer = true
        let previous = container
        if let binding {
            candidates = binding.candidates
            container = IssueContainer(provider: .github, id: binding.selected.slug)
            phase = .ready
        } else {
            candidates = []
            container = nil
            phase = .unbound
        }
        // A re-resolve that lands somewhere else — Refresh after a fork-parent probe
        // that failed on the first try — gets the same reset an explicit pick does, so
        // the fork's issues can't sit under the parent's name while its list loads.
        if previous != nil, previous != container { clearRepositoryScopedState() }
    }

    /// Drops everything belonging to the repository the pane was showing. Both ways
    /// the binding can move — the user's own pick and a Refresh that re-resolves —
    /// go through here, so neither can leave one repository's issues, labels, or open
    /// detail under another's name.
    private func clearRepositoryScopedState() {
        items = []
        openItem = nil
        detail = nil
        detailError = nil
        errorMessage = nil
        recovery = nil
        // Labels belong to the repository that offered them, so both the filter menu's
        // contents and any selection carried over from the previous one are wrong here.
        availableLabels = []
        isRebinding = true
        query.labels = []
        isRebinding = false
    }

    /// Whether the last fork-parent probe failed rather than answering — an offline
    /// launch, a rate limit. The pane is then bound to the fork with a one-entry
    /// menu it hides, which is the very dead end #427 is about, so an explicit
    /// Refresh re-runs the whole resolve instead of only re-fetching the list.
    private var forkParentUnknown = false

    private func forkParent(of slug: String) async -> String? {
        if Self.probedForForkParent.contains(slug) { return Self.forkParents[slug] }
        guard let provider else { return nil }
        do {
            let parent = try await provider.forkParent(of: slug)
            Self.probedForForkParent.insert(slug)
            Self.forkParents[slug] = parent
            forkParentUnknown = false
            return parent
        } catch {
            // Unrecorded on purpose, so a later attempt can still succeed: one offline
            // launch must not pin the pane to the fork for the rest of the session.
            Log.issues.error("fork-parent probe failed for \(slug, privacy: .public): \(error, privacy: .public)")
            forkParentUnknown = true
            return nil
        }
    }

    /// Rebinds the pane to another of this checkout's repositories and remembers it,
    /// so the choice survives a relaunch and holds across the repo's worktrees.
    func selectRepository(slug: String) {
        guard slug != container?.id, candidates.contains(where: { $0.slug == slug }) else { return }
        container = IssueContainer(provider: .github, id: slug)
        clearRepositoryScopedState()
        Task { await GitService.setIssuesRepository(slug, in: repoRoot) }
        Task { await loadList() }
    }

    /// The repo's labels, for the filter menu — loaded once per pane.
    @Published private(set) var availableLabels: [IssueLabel] = []

    func toggleLabelFilter(_ name: String) {
        if query.labels.contains(name) {
            query.labels.remove(name)
        } else {
            query.labels.insert(name)
        }
    }

    private func loadLabels() async {
        guard let provider, let container, availableLabels.isEmpty else { return }
        let loaded = (try? await provider.availableLabels(in: container)) ?? []
        // Labels belong to the repository that served them; a switch mid-fetch must not
        // fill the filter menu with the previous one's.
        guard self.container == container else { return }
        availableLabels = loaded
    }

    /// `force` bypasses the cache for an explicit user refresh (the toolbar button / Try Again),
    /// which must always re-fetch; automatic loads (appear, session switch, filter change) leave it
    /// `false` so they read the cache.
    func loadList(force: Bool = false) async {
        // An explicit Refresh is also the way out of a binding that a failed fork-parent
        // probe left on the fork — re-walk the ladder before re-fetching anything.
        if force, forkParentUnknown {
            didResolveContainer = false
            await resolveContainer()
        }
        guard let provider, let container, phase == .ready else { return }
        if availableLabels.isEmpty { Task { await loadLabels() } }
        // Capture the request's identity: a filter / kind change queues its own `loadList`
        // (see the `query` didSet) and a repository switch rebinds `container`, either of
        // which can land while this fetch is in flight. Both are checked before publishing,
        // so a slow result can never overwrite a newer one — or show repository A's issues
        // under repository B's name.
        let query = self.query

        // Warm: render the cached list instantly (no spinner), then revalidate past the dedupe
        // window — the same stale-while-revalidate the detail uses, so a session switch shows the
        // list immediately instead of reloading it.
        if !force, let cached = cache?.list(container, query) {
            items = cached.items
            errorMessage = nil
            recovery = nil
            guard Date().timeIntervalSince(cached.fetchedAt) >= Self.revalidateAfter else { return }
            do {
                let fresh = try await provider.issues(in: container, query: query)
                // A newer loadList — or another repository — owns the list now.
                guard self.query == query, self.container == container else { return }
                cache?.storeList(fresh, container, query)
                if fresh != items { items = fresh }  // republish only on a real change — no flicker
            } catch {
                // Revalidation failed (offline, rate limit): keep the cached list, stay silent.
            }
            return
        }

        // Cold: spinner + fetch.
        isLoading = true
        errorMessage = nil
        recovery = nil
        do {
            let fetched = try await provider.issues(in: container, query: query)
            guard self.query == query, self.container == container else { isLoading = false; return }
            items = fetched
            cache?.storeList(fetched, container, query)
        } catch {
            handleListError(error)
        }
        isLoading = false
    }

    /// Maps a list-fetch failure to the pane's error + recovery state (shared by the cold load;
    /// a background revalidation swallows its errors and keeps the cached list instead).
    private func handleListError(_ error: Error) {
        // A revoked token must degrade to the connect zero state, not wedge.
        if case GitHubIssueProvider.APIError.status(401) = error {
            disconnect()
        } else if case GitHubIssueProvider.APIError.status(403) = error {
            // A genuine 403 (rate-limit 403s are classified as `.rateLimited` upstream) means the
            // token is valid but has no rights to *this* repo — usually an org that hasn't authorized
            // fyolo. This is the one case reconnect / grant-org access can fix.
            errorMessage = error.localizedDescription
            recovery = .reauthorize
        } else {
            // Rate limits, 404, 5xx, decode, network: reconnecting won't help — offer a retry.
            errorMessage = error.localizedDescription
            recovery = .retry
        }
    }

    /// How long a cached entry counts as fresh enough to skip revalidation — the
    /// stale-while-revalidate dedupe window (SWR's `dedupingInterval`). Rapid tab / session
    /// flipping inside it reads the cache with no network at all; past it the cached copy still
    /// shows instantly, but a silent background refresh confirms it.
    private static let revalidateAfter: TimeInterval = 30

    /// Confirms the open detail against GitHub once its cached copy has aged past the dedupe
    /// window — the revalidate half of stale-while-revalidate, shared by the warm `loadDetail`
    /// path, a same-item reopen, and app refocus. This is what lets a detail notice an
    /// out-of-band state change: a PR closed by `gh` in a terminal or on github.com keeps
    /// showing its stale Open badge until some interaction lands here.
    func revalidateOpenDetail() async {
        await ensureReady()
        guard let provider, let container, let item = openItem else { return }
        guard let cached = cache?.entry(container, item.number),
              Date().timeIntervalSince(cached.fetchedAt) >= Self.revalidateAfter
        else { return }
        do {
            let fresh = try await fetchEntry(item, provider: provider, container: container)
            guard openItem?.number == item.number else { return }
            cache?.store(fresh, container, item.number)
            // Only republish on a real change, so an unchanged refresh never flickers.
            if !fresh.sameContent(as: cached) { apply(fresh) }
        } catch {
            // Revalidation failed (offline, rate limit): the cached copy already shows.
        }
    }

    func loadDetail(for item: IssueSummary) async {
        // A session switch remounts `IssuesView` with a brand-new, empty model, so make this
        // self-sufficient rather than assuming `start()` has already run: resolve the token +
        // binding here if needed. Without the container the cache key can't be formed, so every
        // open would fall straight through to the network — which is what made the cache look
        // useless on exactly the switch path it exists for.
        await ensureReady()
        guard let provider, let container else { return }
        // Same item already loaded in this instance (e.g. a maximize remount): the content
        // already shows — just confirm it, so a reopen picks up a state change that happened
        // while the detail was up (a PR closed out of band).
        if openItem?.number == item.number, detail != nil, !prFilesLoading {
            await revalidateOpenDetail()
            return
        }
        // The model's own record of which item is open, independent of what drives the UI.
        openItem = item

        // Warm: a prior fetch of this remote item is cached — possibly by another session, a
        // different worktree of the same repo, or the model this replaced. Render it instantly:
        // no `detail = nil` wipe, no spinner.
        if let cached = cache?.entry(container, item.number) {
            apply(cached)
            if item.kind == .pullRequest, !cached.filesLoaded {
                // Only the conversation was cached (opened, then switched away before the file
                // list landed): fetch just the files now — the conversation already shows.
                await loadPRFiles(item, provider: provider, container: container,
                                  conversation: cached.detail)
            } else {
                await revalidateOpenDetail()
            }
            return
        }

        // Cold: nothing cached — wipe to the spinner and fetch the conversation.
        detail = nil
        detailError = nil
        prFiles = []
        prFilePatches = [:]
        prFileContentURLs = [:]
        prFilesLoading = false
        do {
            let conversation = try await provider.detail(item.number, in: container)
            guard openItem?.number == item.number else { return }  // user moved on mid-fetch
            detail = conversation
            // Cache the conversation the moment it lands — before a PR's heavy file list — so a
            // switch-away still warms the cache. `filesLoaded: false` marks the pending files.
            cache?.store(
                .init(detail: conversation, prFiles: [], prFilePatches: [:], prFileContentURLs: [:],
                      filesLoaded: item.kind != .pullRequest, fetchedAt: Date()),
                container, item.number)
            if item.kind == .pullRequest {
                await loadPRFiles(item, provider: provider, container: container,
                                  conversation: conversation)
            }
        } catch {
            detailError = error.localizedDescription
        }
    }

    /// Fetches a PR's changed files (`/files` carries every patch inline, the heavy part) and folds
    /// them into the already-shown conversation, upgrading the cache entry to
    /// `filesLoaded: true`. Runs behind the conversation so the default tab never waits on it; a
    /// failure just leaves the Files tab empty rather than erroring the whole detail.
    private func loadPRFiles(_ item: IssueSummary, provider: GitHubIssueProvider,
                             container: IssueContainer, conversation: IssueDetail) async {
        prFilesLoading = true
        do {
            let loadedFiles = try await provider.pullRequestFiles(item.number, in: container)
            guard openItem?.number == item.number else { prFilesLoading = false; return }
            let mapped = prFileMapping(loadedFiles)
            prFiles = mapped.changes
            prFilePatches = mapped.patches
            prFileContentURLs = mapped.contentURLs
            cache?.store(
                .init(detail: conversation, prFiles: mapped.changes, prFilePatches: mapped.patches, prFileContentURLs: mapped.contentURLs,
                      filesLoaded: true, fetchedAt: Date()),
                container, item.number)
        } catch {
            // The conversation stays; the Files tab simply shows no files.
        }
        prFilesLoading = false
    }

    /// Reads one PR file at the head, for a diff pane that wants to expand past the three
    /// lines of context GitHub's patch carries. Nil whenever that cannot be done — no
    /// provider, no `contents_url`, a binary blob, or the request failing — and the pane
    /// then leaves its bands inert rather than offering a control that would do nothing.
    func prFileText(_ path: String) async -> String? {
        guard let provider, let url = prFileContentURLs[path] else { return nil }
        return try? await provider.fileText(at: url)
    }

    /// Maps GitHub's `/files` payload into the git pane's `GitChange` rows plus each file's inline
    /// unified-diff patch keyed by path — what the Files tab renders with no further network or git
    /// work. Absent patch keys are files GitHub gave none for (binary / diff too large to inline).
    private func prFileMapping(
        _ files: [PullRequestFile]
    ) -> (changes: [GitChange], patches: [String: String], contentURLs: [String: URL]) {
        let patches = Dictionary(
            uniqueKeysWithValues: files.compactMap { file in
                file.patch.map { (file.change.path, $0) }
            })
        let contentURLs = Dictionary(
            uniqueKeysWithValues: files.compactMap { file in
                file.contentsURL.map { (file.change.path, $0) }
            })
        return (files.map(\.change), patches, contentURLs)
    }

    /// Publishes a fetched entry into the pane's detail state.
    private func apply(_ entry: IssueCache.Entry) {
        detail = entry.detail
        prFiles = entry.prFiles
        prFilePatches = entry.prFilePatches
        prFileContentURLs = entry.prFileContentURLs
        prFilesLoading = false
        detailError = nil
    }

    /// One network round-trip for an item's full detail: the conversation, and for a PR its
    /// changed files (with each file's inline patch keyed by path). Pure fetch — no state
    /// writes — so both the cold and revalidation paths share it.
    private func fetchEntry(
        _ item: IssueSummary,
        provider: GitHubIssueProvider,
        container: IssueContainer
    ) async throws -> IssueCache.Entry {
        if item.kind == .pullRequest {
            async let loadedDetail = provider.detail(item.number, in: container)
            async let files = provider.pullRequestFiles(item.number, in: container)
            let (detail, loadedFiles) = try await (loadedDetail, files)
            let mapped = prFileMapping(loadedFiles)
            return .init(
                detail: detail, prFiles: mapped.changes, prFilePatches: mapped.patches, prFileContentURLs: mapped.contentURLs,
                filesLoaded: true, fetchedAt: Date())
        } else {
            let detail = try await provider.detail(item.number, in: container)
            return .init(
                detail: detail, prFiles: [], prFilePatches: [:], prFileContentURLs: [:],
                filesLoaded: true, fetchedAt: Date())
        }
    }

    // MARK: Pull-request extras

    /// The PR's changed files (empty for issues).
    @Published private(set) var prFiles: [GitChange] = []
    /// Each file's inline unified-diff patch from the API, keyed by path — what the Files
    /// tab renders. Absent keys are files GitHub gave no patch for (binary / too large).
    @Published private(set) var prFilePatches: [String: String] = [:]
    /// Each PR file's `contents_url`, pinned to the head — the Files tab reads the file
    /// through it to expand the context GitHub's three-line patch left out.
    @Published private(set) var prFileContentURLs: [String: URL] = [:]

    /// The PR's file list is still in flight *after* the conversation has already rendered —
    /// the two are fetched separately so the (small, fast) conversation isn't gated behind the
    /// (heavy — every patch inline) `/files` response. Drives the Files tab's own spinner so a
    /// user who taps Files early sees loading, not a wrong "No Files".
    @Published private(set) var prFilesLoading = false
}
