import AppKit
import Combine
import Foundation

/// The pull requests and tickets behind Group by Task, read through the GitHub
/// and Linear connections the user already made — fyolo asks for nothing new.
///
/// Asked from the grouping pass itself (`FyoloStore.taskLayout`), so only the
/// projects on screen with the mode on cost a request, and each at most once a
/// minute unless what it asks about changes. A failed read keeps the last
/// answer: these facts only rename and relink tasks, so stale beats missing.
@MainActor
final class TaskFactsLoader: ObservableObject {
    @Published private(set) var facts: [Project.ID: TaskFacts] = [:]
    /// Matches the connected Linear workspace's real team keys once they are
    /// known, and guesses narrowly until then.
    @Published private(set) var pattern = TaskTicketPattern()

    /// What one project's facts were read for. A different request — a new
    /// branch, a new mention, a connection switched on — is read again at once.
    struct Request: Equatable {
        let path: String
        let branches: Set<String>
        let mentions: Set<String>
        let gitHub: Bool
        let linear: Bool
    }

    static let freshness: TimeInterval = 60

    private var answered: [Project.ID: (request: Request, at: Date)] = [:]
    private var inFlight: Set<Project.ID> = []
    private var slugs: [String: String] = [:]
    private var teamKeys: [String] = []
    private var assigned: (tickets: [LinearClient.TicketSummary], at: Date)?
    private var lastAsked = Date.distantPast
    private var observers: [AnyCancellable] = []
    private var timer: Timer?

    init() {
        // The Linear pane's cache holds the viewer this reuses; make sure it is
        // emptied on a connection change even if the pane never opened.
        LinearCache.observeConnections()
        let center = NotificationCenter.default
        observers = [
            center.publisher(for: GitHubIssueAuth.connectionDidChange)
                .merge(with: center.publisher(for: LinearAuth.connectionDidChange))
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.forgetAll() } },
            center.publisher(for: NSApplication.didBecomeActiveNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.expire() } },
        ]
        // A pull request's checks and review move without anything local
        // changing, so a visible grouping re-reads on a slow clock too.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    /// Asks for `project`'s facts. Cheap when they are fresh, so it is called
    /// on every grouping pass; the read itself runs after the pass, never in it.
    func request(_ project: Project.ID, _ request: Request) {
        lastAsked = Date()
        guard !inFlight.contains(project) else { return }
        if let answer = answered[project], answer.request == request,
           Date().timeIntervalSince(answer.at) < Self.freshness {
            return
        }
        inFlight.insert(project)
        Task { [weak self] in await self?.load(project, request) }
    }

    private func load(_ project: Project.ID, _ request: Request) async {
        defer { inFlight.remove(project) }
        var failed = false

        var headed: [String: LinkedPullRequest] = [:]
        if request.gitHub, !request.branches.isEmpty, let github = GitHubIssueAuth.storedConnection() {
            do {
                if let slug = await slug(for: request.path, host: github.host) {
                    headed = try await GitHubPullRequestLookup(connection: github)
                        .headedBy(request.branches.sorted(), in: slug)
                }
            } catch {
                failed = true
                Log.issues.error("task pull requests for \(request.path, privacy: .public) failed: \(error, privacy: .public)")
            }
        }

        var tickets: [LinearClient.TicketSummary] = []
        if request.linear, let linear = LinearAuth.storedConnection() {
            do {
                let client = LinearClient(connection: linear)
                let viewer: LinearClient.Viewer
                if let cached = LinearCache.viewer {
                    viewer = cached
                } else {
                    viewer = try await client.viewer()
                    LinearCache.viewer = viewer
                }
                adopt(teamKeys: viewer.teams.map(\.key))
                let wanted = Self.identifiers(
                    branches: request.branches, titles: headed.values.map(\.title),
                    mentions: request.mentions, pattern: pattern)
                let relevant = try await assignedTickets(client).filter { ticket in
                    wanted.contains(ticket.identifier)
                        || ticket.branchName.map(request.branches.contains) == true
                }
                let missing = wanted.subtracting(relevant.map(\.identifier))
                let lookedUp = missing.isEmpty ? [] : try await client.tickets(missing.sorted())
                tickets = relevant + lookedUp
            } catch {
                failed = true
                Log.issues.error("task tickets for \(request.path, privacy: .public) failed: \(error, privacy: .public)")
            }
        }

        answered[project] = (request, Date())
        if failed, facts[project] != nil { return }
        let assembled = Self.assemble(headed: headed, tickets: tickets)
        if facts[project] != assembled { facts[project] = assembled }
    }

    /// The viewer's open tickets, shared by every project for a minute.
    private func assignedTickets(_ client: LinearClient) async throws -> [LinearClient.TicketSummary] {
        if let assigned, Date().timeIntervalSince(assigned.at) < Self.freshness { return assigned.tickets }
        let tickets = try await client.assignedOpenTickets()
        assigned = (tickets, Date())
        return tickets
    }

    private func adopt(teamKeys keys: [String]) {
        let sorted = keys.sorted()
        guard sorted != teamKeys else { return }
        teamKeys = sorted
        pattern = TaskTicketPattern(teamKeys: sorted)
    }

    /// `owner/name` of the project's GitHub repository: the one picked for the
    /// Issues pane, else the first GitHub remote.
    private func slug(for path: String, host: String) async -> String? {
        if let known = slugs[path] { return known.isEmpty ? nil : known }
        var found = await GitService.issuesRepository(in: path)
        if found == nil { found = await GitService.gitHubRemotes(in: path, host: host).first?.slug }
        slugs[path] = found ?? ""
        return found
    }

    /// Everything known goes stale: the next grouping pass reads again.
    /// Skipped when nothing has asked lately, so an idle sidebar isn't redrawn.
    private func expire() {
        guard Date().timeIntervalSince(lastAsked) < 300 else { return }
        answered.removeAll()
        slugs.removeAll()
        objectWillChange.send()
    }

    /// A connection changed: nothing read through the old one may show.
    private func forgetAll() {
        answered.removeAll()
        slugs.removeAll()
        assigned = nil
        teamKeys = []
        pattern = TaskTicketPattern()
        facts.removeAll()
    }

    /// The ticket identifiers worth asking Linear about: those named by the
    /// branches, by their pull requests' titles, and by prompts — with the real
    /// pattern, so a mention of another workspace's key is not asked about.
    nonisolated static func identifiers(branches: Set<String>, titles: [String], mentions: Set<String>,
                            pattern: TaskTicketPattern) -> Set<String> {
        var found = Set(branches.flatMap(pattern.identifiers(inBranch:)))
        found.formUnion(titles.flatMap(pattern.identifiers(inText:)))
        found.formUnion(mentions.flatMap(pattern.identifiers(inText:)))
        return found
    }

    nonisolated static func assemble(headed: [String: LinkedPullRequest],
                         tickets: [LinearClient.TicketSummary]) -> TaskFacts {
        let pullRequests = headed.keys.sorted().compactMap { branch -> TaskFacts.PullRequest? in
            guard let pullRequest = headed[branch] else { return nil }
            return TaskFacts.PullRequest(
                number: pullRequest.number,
                branch: branch,
                title: pullRequest.title,
                isFinished: pullRequest.status == .merged || pullRequest.status == .closed,
                status: pullRequest.status,
                url: pullRequest.url)
        }
        var seen = Set<String>()
        let summaries = tickets.filter { seen.insert($0.identifier).inserted }.map { ticket in
            TaskFacts.Ticket(
                identifier: ticket.identifier,
                title: ticket.title,
                branchName: ticket.branchName,
                isFinished: ticket.isFinished,
                url: ticket.url)
        }
        return TaskFacts(pullRequests: pullRequests, tickets: summaries)
    }
}
