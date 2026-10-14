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
    /// The pull requests whose titles name a ticket, keyed by the GitHub account
    /// searched and the identifier. An empty list records a ticket with none.
    static var pullRequests: [String: Stamped<[LinkedPullRequest]>] = [:]
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
        pullRequests.removeAll()
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
    /// Pull requests by ticket identifier, for the tickets looked up so far: the
    /// viewer's own as the list loads, any other once it is opened.
    @Published private(set) var pullRequests: [String: [LinkedPullRequest]] = [:]

    /// Tickets pushed into the pane, newest last. Empty shows the list.
    @Published var path: [String] = []
    @Published private(set) var details: [String: LinearIssueDetail] = [:]
    @Published private(set) var detailError: String?

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
                        self?.pullRequests = [:]
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
        pullRequests = [:]
        errorMessage = nil
        needsReconnect = false
        Task { await start() }
    }

    // MARK: Loading

    /// Entry point on appear: restore the connection, settle the team, and load
    /// the list, then the pull requests for the viewer's tickets in it.
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

    /// The list, then the chips for the viewer's part of it — which tickets
    /// those are isn't known until the list is in.
    func reload(force: Bool) async {
        await loadIssues(force: force)
        await loadPullRequests(force: force)
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

    /// How many of the viewer's tickets get chips in the list: eight searches,
    /// in one request. The tickets are in priority order, so the cut falls on
    /// the least pressing; any ticket past it still shows its PRs when opened.
    static let listedPullRequestLimit = 8 * GitHubPullRequestLookup.identifiersPerSearch

    /// Chips for the viewer's own tickets only. Everyone else's tickets get their
    /// pull requests when opened, so what the list costs follows how much of the
    /// work is yours, not how big the team or its pull request history is.
    func loadPullRequests(force: Bool) async {
        let identifiers = mine.prefix(Self.listedPullRequestLimit).map(\.identifier)
        await lookUpPullRequests(for: identifiers, force: force)
    }

    /// Searches GitHub for whichever of `identifiers` have no fresh answer, in one
    /// request, and publishes every answer. Silent when GitHub isn't connected or
    /// the project isn't on GitHub — the chips simply don't appear.
    private func lookUpPullRequests(for identifiers: [String], force: Bool) async {
        guard gitHubEnabled(), let github = GitHubIssueAuth.storedConnection() else {
            if !pullRequests.isEmpty { pullRequests = [:] }
            return
        }
        guard !identifiers.isEmpty, let pattern, let owner = await repositoryOwner(host: github.host) else { return }
        var known = pullRequests
        var stale: [String] = []
        for identifier in identifiers {
            if let cached = LinearCache.pullRequests[owner + "\u{0}" + identifier] {
                known[identifier] = cached.value
                if cached.isFresh, !force { continue }
            }
            stale.append(identifier)
        }
        if known != pullRequests { pullRequests = known }
        guard !stale.isEmpty else { return }
        do {
            let found = try await GitHubPullRequestLookup(connection: github).mentioning(stale, owner: owner)
            let now = Date()
            var updated = pullRequests
            for (identifier, matches) in pattern.index(found, for: stale) {
                LinearCache.pullRequests[owner + "\u{0}" + identifier] = .init(value: matches, fetchedAt: now)
                updated[identifier] = matches
            }
            if updated != pullRequests { pullRequests = updated }
        } catch {
            // The chips are decoration; a failed search leaves the list as it is.
            Log.issues.error("pull request search under \(owner, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// The account that owns the project's GitHub repository — the scope every
    /// search runs in, so it reaches the owner's other repositories too.
    private func repositoryOwner(host: String) async -> String? {
        if repositorySlug == nil {
            if let picked = await GitService.issuesRepository(in: projectRoot) {
                repositorySlug = picked
            } else {
                repositorySlug = await GitService.gitHubRemotes(in: projectRoot, host: host).first?.slug
            }
        }
        return repositorySlug?.split(separator: "/").first.map(String.init)
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
            await lookUpPullRequests(for: [detail.identifier], force: false)
        } catch {
            if details[key] == nil { detailError = error.localizedDescription }
            if case LinearAPIError.unauthorized = error { needsReconnect = true }
        }
    }

    /// Every pull request known to name `identifier`, newest number first.
    func pullRequests(for identifier: String) -> [LinkedPullRequest] {
        (pullRequests[identifier] ?? []).sorted { $0.number > $1.number }
    }
}
