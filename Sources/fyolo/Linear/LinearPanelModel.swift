import AppKit
import Combine
import Foundation

// MARK: - Cache

/// What the Linear pane has fetched, held above the per-project model so a tab
/// switch or a session switch redraws from memory and revalidates behind it —
/// the `IssueCache` pattern. Emptied whenever either connection changes, so no
/// account ever reads another's tickets or pull requests.
@MainActor
enum LinearCache {
    struct Stamped<Value> {
        let value: Value
        let fetchedAt: Date

        var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < 30 }
    }

    static var viewer: LinearClient.Viewer?
    static var issues: [String: Stamped<[LinearIssue]>] = [:]
    static var details: [String: LinearIssueDetail] = [:]
    /// Recent pull requests by repository slug, indexed by ticket identifier.
    static var pullRequestIndex: [String: Stamped<[String: [LinkedPullRequest]]>] = [:]
    /// Search results by ticket identifier, for tickets the recent window missed.
    static var searchedPullRequests: [String: [LinkedPullRequest]] = [:]
    /// Team picks for folders git doesn't track, which have no config to keep them.
    static var teamByFolder: [String: String] = [:]

    private static var observers: [AnyCancellable] = []

    static func observeConnections() {
        guard observers.isEmpty else { return }
        observers = [
            NotificationCenter.default.publisher(for: LinearAuth.connectionDidChange)
                .receive(on: RunLoop.main)
                .sink { _ in MainActor.assumeIsolated { clearLinear() } },
            NotificationCenter.default.publisher(for: GitHubIssueAuth.connectionDidChange)
                .receive(on: RunLoop.main)
                .sink { _ in MainActor.assumeIsolated { clearPullRequests() } },
        ]
    }

    private static func clearLinear() {
        viewer = nil
        issues.removeAll()
        details.removeAll()
        clearPullRequests()
    }

    private static func clearPullRequests() {
        pullRequestIndex.removeAll()
        searchedPullRequests.removeAll()
    }
}

// MARK: - Pane state

/// State for the Linear pane, per project root (recreated by `.id(projectRoot)`):
/// the connection, the team the project reads, the ordered tickets, the pull
/// requests their titles name, and the stack of tickets pushed into the pane.
@MainActor
final class LinearPanelModel: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case loading
        /// Connected to a workspace with several teams and no pick for this project yet.
        case choosingTeam
        case ready
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var teams: [LinearTeam] = []
    @Published private(set) var team: LinearTeam?
    @Published private(set) var mine: [LinearIssue] = []
    @Published private(set) var others: [LinearIssue] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// The error can only be fixed by signing in again.
    @Published private(set) var needsReconnect = false
    @Published private(set) var pullRequestIndex: [String: [LinkedPullRequest]] = [:]

    /// Tickets pushed into the pane, newest last. Empty shows the list.
    @Published var path: [String] = []
    @Published private(set) var details: [String: LinearIssueDetail] = [:]
    @Published private(set) var detailError: String?
    @Published private(set) var searchedPullRequests: [String: [LinkedPullRequest]] = [:]

    @Published private(set) var isSigningIn = false
    @Published private(set) var connectError: String?

    let projectRoot: String
    /// Read live, so turning the General ▸ GitHub switch off drops the chips
    /// on the next load without a remount.
    private let gitHubEnabled: () -> Bool

    private var connection: LinearConnection?
    private var pattern: LinearTicketPattern?
    private var repositorySlug: String?
    private var connectionObservers: [AnyCancellable] = []

    init(projectRoot: String, gitHubEnabled: @escaping () -> Bool) {
        self.projectRoot = projectRoot
        self.gitHubEnabled = gitHubEnabled
        LinearCache.observeConnections()
        connectionObservers = [
            NotificationCenter.default.publisher(for: LinearAuth.connectionDidChange)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.connectionDidChange() } },
            NotificationCenter.default.publisher(for: GitHubIssueAuth.connectionDidChange)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.pullRequestIndex = [:]
                        self?.searchedPullRequests = [:]
                        Task { await self?.loadPullRequests(force: true) }
                    }
                },
        ]
    }

    // MARK: Connect

    func signIn() {
        connectError = nil
        isSigningIn = true
        Task {
            defer { isSigningIn = false }
            do {
                LinearAuth.store(try await LinearAuth.connectInBrowser())
            } catch {
                connectError = error.localizedDescription
            }
        }
    }

    /// Checks a pasted key against Linear before keeping it.
    func connect(apiKey rawKey: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            connectError = localized("Paste a key first.")
            return
        }
        connectError = nil
        isSigningIn = true
        Task {
            defer { isSigningIn = false }
            let candidate = LinearConnection(accessToken: key, refreshToken: nil, expiresAt: nil, source: .apiKey)
            do {
                _ = try await LinearClient(connection: candidate).viewer()
                LinearAuth.store(candidate)
            } catch LinearAPIError.unauthorized {
                connectError = localized("Linear rejected this key. Check that it was copied whole.")
            } catch {
                connectError = error.localizedDescription
            }
        }
    }

    func disconnect() {
        LinearAuth.disconnect()
    }

    private func connectionDidChange() {
        connection = nil
        team = nil
        mine = []
        others = []
        path = []
        details = [:]
        pullRequestIndex = [:]
        searchedPullRequests = [:]
        errorMessage = nil
        needsReconnect = false
        Task { await start() }
    }

    // MARK: Loading

    /// Entry point on appear: restore the connection, settle the team, and load
    /// the list and its pull requests side by side.
    func start() async {
        guard let stored = LinearAuth.storedConnection() else {
            phase = .disconnected
            return
        }
        connection = stored
        if phase == .disconnected { phase = .loading }
        do {
            let viewer = try await currentViewer(stored)
            teams = viewer.teams
            pattern = LinearTicketPattern(teamKeys: viewer.teams.map(\.key))
        } catch {
            handle(error)
            return
        }
        if team == nil { team = await rememberedTeam() }
        guard team != nil else {
            phase = .choosingTeam
            return
        }
        await reload(force: false)
    }

    func choose(_ team: LinearTeam) {
        self.team = team
        mine = []
        others = []
        path = []
        Task {
            if !(await GitService.setLinearTeam(team.id, in: projectRoot)) {
                LinearCache.teamByFolder[projectRoot] = team.id
            }
            await reload(force: false)
        }
    }

    /// The list and the pull request index together; neither waits on the other.
    func reload(force: Bool) async {
        async let issues: Void = loadIssues(force: force)
        async let pullRequests: Void = loadPullRequests(force: force)
        _ = await (issues, pullRequests)
    }

    private func loadIssues(force: Bool) async {
        guard let connection, let team else { return }
        let viewerID = LinearCache.viewer?.id
        if let cached = LinearCache.issues[team.id] {
            apply(cached.value, viewerID: viewerID)
            phase = .ready
            if cached.isFresh, !force { return }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let issues = try await LinearClient(connection: connection).openIssues(teamID: team.id)
            // The pick may have moved while the request was out.
            guard self.team?.id == team.id else { return }
            LinearCache.issues[team.id] = .init(value: issues, fetchedAt: Date())
            apply(issues, viewerID: viewerID)
            errorMessage = nil
            needsReconnect = false
            phase = .ready
        } catch {
            handle(error)
        }
    }

    private func apply(_ issues: [LinearIssue], viewerID: String?) {
        let split = LinearIssueOrdering.split(issues, viewerID: viewerID)
        if split.mine != mine { mine = split.mine }
        if split.others != others { others = split.others }
    }

    /// The project's GitHub repository's recent pull requests, indexed by the
    /// tickets their titles name. Silent when GitHub isn't connected or the
    /// project isn't on GitHub — the chips simply don't appear.
    func loadPullRequests(force: Bool) async {
        guard gitHubEnabled(), let github = GitHubIssueAuth.storedConnection(), let pattern else {
            pullRequestIndex = [:]
            return
        }
        if repositorySlug == nil {
            if let picked = await GitService.issuesRepository(in: projectRoot) {
                repositorySlug = picked
            } else {
                repositorySlug = await GitService.gitHubRemotes(in: projectRoot, host: github.host).first?.slug
            }
        }
        guard let slug = repositorySlug else { return }
        if let cached = LinearCache.pullRequestIndex[slug] {
            pullRequestIndex = cached.value
            if cached.isFresh, !force { return }
        }
        do {
            let recent = try await GitHubPullRequestLookup(connection: github).recent(in: slug)
            let index = pattern.index(recent)
            LinearCache.pullRequestIndex[slug] = .init(value: index, fetchedAt: Date())
            if index != pullRequestIndex { pullRequestIndex = index }
        } catch {
            // The chips are decoration; a failed read leaves the list as it is.
            Log.issues.error("recent pull requests for \(slug, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    private func currentViewer(_ connection: LinearConnection) async throws -> LinearClient.Viewer {
        if let viewer = LinearCache.viewer { return viewer }
        let viewer = try await LinearClient(connection: connection).viewer()
        LinearCache.viewer = viewer
        return viewer
    }

    /// The project's recorded team, or the only team there is.
    private func rememberedTeam() async -> LinearTeam? {
        let recorded = await GitService.linearTeam(in: projectRoot) ?? LinearCache.teamByFolder[projectRoot]
        if let recorded, let match = teams.first(where: { $0.id == recorded }) { return match }
        return teams.count == 1 ? teams.first : nil
    }

    private func handle(_ error: Error) {
        if case LinearAPIError.unauthorized = error { needsReconnect = true }
        errorMessage = error.localizedDescription
        if phase == .loading { phase = .ready }
    }

    // MARK: Detail

    func open(_ key: String) {
        guard path.last != key else { return }
        path.append(key)
    }

    func back() {
        _ = path.popLast()
    }

    /// Opens a Linear link from a ticket's page in the pane, when it names a
    /// ticket (`linear.app/<workspace>/issue/ENG-123/…`). `false` for anything
    /// else, which then opens in the browser.
    func openIfTicket(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "linear.app" else { return false }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "issue"), parts.indices.contains(index + 1) else { return false }
        open(parts[index + 1].uppercased())
        return true
    }

    func loadDetail(_ key: String) async {
        guard let connection else { return }
        detailError = nil
        if let cached = LinearCache.details[key] {
            details[key] = cached
        }
        do {
            let detail = try await LinearClient(connection: connection).issue(key)
            LinearCache.details[key] = detail
            if details[key] != detail { details[key] = detail }
            await searchPullRequests(for: detail.identifier)
        } catch {
            if details[key] == nil { detailError = error.localizedDescription }
            if case LinearAPIError.unauthorized = error { needsReconnect = true }
        }
    }

    /// Pull requests for a ticket the recent window had nothing for: one title
    /// search across the repository owner's account, each hit re-checked
    /// against the pattern because GitHub's search matches words, not tokens.
    private func searchPullRequests(for identifier: String) async {
        guard pullRequestIndex[identifier] == nil, gitHubEnabled(),
              let github = GitHubIssueAuth.storedConnection(), let pattern,
              let owner = repositorySlug?.split(separator: "/").first.map(String.init)
        else { return }
        if let cached = LinearCache.searchedPullRequests[identifier] {
            searchedPullRequests[identifier] = cached
            return
        }
        do {
            let found = try await GitHubPullRequestLookup(connection: github).mentioning(identifier, owner: owner)
            let matching = found.filter { pattern.identifiers(in: $0.title).contains(identifier) }
            LinearCache.searchedPullRequests[identifier] = matching
            searchedPullRequests[identifier] = matching
        } catch {
            Log.issues.error("pull request search for \(identifier, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// Every pull request known to name `identifier`, newest number first.
    func pullRequests(for identifier: String) -> [LinkedPullRequest] {
        var seen = Set<URL>()
        return ((pullRequestIndex[identifier] ?? []) + (searchedPullRequests[identifier] ?? []))
            .filter { seen.insert($0.url).inserted }
            .sorted { $0.number > $1.number }
    }
}
