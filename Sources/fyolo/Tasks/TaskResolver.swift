import Foundation

/// The facts a session was opened with that say which task it belongs to.
/// Each one is recorded when it happens, because the live state it came from
/// moves on: the main checkout switches branch under running shells, and the
/// session a split was made from can close.
struct TaskAnchor: Hashable, Codable {
    /// The branch the session's checkout was on when it was opened, or when its
    /// agent took its first prompt. Only consulted for the project's main
    /// checkout — a worktree's sessions follow the worktree's own branch.
    var branch: String?
    /// The session this one was split or ⌘T'd from. It goes wherever that one
    /// goes, which is what puts a companion shell beside its agent.
    var origin: Session.ID?
    /// Tickets the agent's first prompt named. Weak: they place a session that
    /// has no other evidence, and never join two tasks together.
    var mentionedTickets: [String] = []
}

/// A session's task chosen by hand.
enum TaskOverride: Hashable, Codable {
    /// Kept out of every task, as a plain row under the project.
    case excluded
    /// Filed under the task holding this node (`TaskGroup.ID` or any node of it).
    case task(String)
}

/// Pull requests and tickets the trackers know about. Empty when nothing is
/// connected; the resolver then works from branches, worktrees and lineage alone.
struct TaskFacts: Hashable, Sendable {
    struct PullRequest: Hashable, Sendable {
        let number: Int
        /// The head branch, matched against the branches sessions sit on.
        let branch: String
        let title: String
        /// Merged or closed.
        let isFinished: Bool
        var status: LinkedPullRequestStatus? = nil
        var url: URL? = nil
    }

    struct Ticket: Hashable, Sendable {
        let identifier: String
        let title: String
        /// The branch name the tracker suggests for the ticket, when it has one.
        let branchName: String?
        /// Done or canceled.
        let isFinished: Bool
        var url: URL? = nil
    }

    var pullRequests: [PullRequest] = []
    var tickets: [Ticket] = []

    static let none = TaskFacts()
}

/// Ticket identifiers (`ENG-412`) in branch names and prompt text.
///
/// With the tracker's real team keys it matches only those, in any case. Without
/// them it guesses, and guesses narrowly: in a branch only a whole path segment
/// that starts with `key-number` counts (`flo/eng-412-rate-limit`), and in prose
/// only the uppercase spelling. A list of look-alikes that are never tickets
/// (`UTF-8`, `fix-12`) is refused in both.
struct TaskTicketPattern: Sendable {
    private let keyed: LinearTicketPattern?

    init(teamKeys: [String] = []) {
        keyed = LinearTicketPattern(teamKeys: teamKeys)
    }

    private static let notTickets: Set<String> = [
        "UTF", "ISO", "RFC", "SHA", "MD", "CVE", "ES", "IE", "WIP", "TEST", "TESTS",
        "FIX", "FIXES", "FEAT", "FEATURE", "BUG", "BUGFIX", "HOTFIX", "CHORE", "DOCS",
        "REFACTOR", "RELEASE", "REL", "ISSUE", "ISSUES", "PR", "STEP", "PART", "PHASE",
        "BUMP", "UPGRADE", "NODE", "PY", "GO", "JS", "TS", "UI",
    ]

    private static let branchExpression = try? NSRegularExpression(
        pattern: "(?:^|[/_])([A-Za-z]{2,6})-([1-9][0-9]{0,5})(?=$|[-_/.])")
    private static let proseExpression = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9-])([A-Z]{2,6})-([1-9][0-9]{0,5})(?![0-9A-Za-z])")
    private static let linkExpression = try? NSRegularExpression(
        pattern: "linear\\.app/[^/\\s]+/issue/([A-Za-z]{2,6})-([0-9]{1,6})")

    func identifiers(inBranch branch: String) -> [String] {
        if let keyed { return keyed.identifiers(in: branch) }
        return Self.matches(Self.branchExpression, in: branch)
    }

    func identifiers(inText text: String) -> [String] {
        let linked = Self.matches(Self.linkExpression, in: text)
        if let keyed { return Self.unique(linked + keyed.identifiers(in: text)) }
        return Self.unique(linked + Self.matches(Self.proseExpression, in: text))
    }

    private static func matches(_ expression: NSRegularExpression?, in text: String) -> [String] {
        guard let expression else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let found = expression.matches(in: text, range: range).compactMap { match -> String? in
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let numberRange = Range(match.range(at: 2), in: text),
                  let number = Int(text[numberRange])
            else { return nil }
            let key = text[keyRange].uppercased()
            guard !notTickets.contains(key) else { return nil }
            return "\(key)-\(number)"
        }
        return unique(found)
    }

    private static func unique(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }
}

/// Why a task holds what it holds, for the header's tooltip. An automatic
/// grouping the user can't see the reason for is one they can't trust.
enum TaskReason: Hashable {
    case worktree(String)
    case branch(String)
    case ticketInBranch(ticket: String, branch: String)
    case ticketBranch(ticket: String, branch: String)
    case pullRequest(number: Int, branch: String)
    case ticketInPullRequest(ticket: String, number: Int)
    case mentioned(String)
    case moved
}

/// One task: the sessions that belong together, and what ties them.
struct TaskGroup: Identifiable, Hashable {
    /// The most durable node in the task — its worktree, else its branch, else
    /// its pull request, else its ticket — so collapsing a task survives the
    /// task learning its ticket. A manual move names this.
    let id: String
    let tickets: [String]
    let branches: [String]
    let folders: [String]
    let pullRequests: [TaskFacts.PullRequest]
    /// The tracker's name for the work, when one is connected and knows it.
    let title: String?
    /// The first ticket's page in the tracker, when one is connected.
    let ticketURL: URL?
    let isFinished: Bool
    let sessionIDs: [Session.ID]
    let reasons: [TaskReason]

    /// What the header leads with: the tracker's title, else the branch verbatim
    /// (a ref is case-sensitive and gets typed into `git checkout`), else the
    /// worktree folder, else the ticket.
    var headline: String {
        title ?? branches.first
            ?? folders.first.map { ($0 as NSString).lastPathComponent }
            ?? tickets.joined(separator: " + ")
    }

    /// The ticket identifiers shown ahead of the headline, unless the headline
    /// already is them.
    var ticketPrefix: String? {
        guard !tickets.isEmpty, title != nil || !branches.isEmpty || !folders.isEmpty
        else { return nil }
        return tickets.joined(separator: " + ")
    }
}

/// A project's sessions arranged into tasks, plus the ones no task claims.
struct TaskLayout: Hashable {
    var groups: [TaskGroup]
    /// Sessions with no evidence of a task, in roster order.
    var loose: [Session.ID]

    func group(containing id: Session.ID) -> TaskGroup? {
        groups.first { $0.sessionIDs.contains(id) }
    }
}

/// Groups one project's sessions into tasks.
///
/// A task is a connected component over worktree folders, branches, pull
/// requests and tickets. A session joins one through, in order: a manual move;
/// the session it was opened from; its own worktree or branch; a split-pane
/// group mate; a ticket its first prompt named. Strong edges (folder–branch,
/// ticket in a branch name, the tracker's branch for a ticket, a pull request's
/// head branch and the tickets its title names) join components. A prompt
/// mention is weak and only places a session that has nothing else, so a
/// passing mention can't fuse two pieces of work into one.
///
/// Trunk branches are never nodes: everything done on `main` would otherwise be
/// one task. A session with no evidence stays loose rather than being guessed
/// into a group. Pure — the store gathers the inputs.
enum TaskResolver {
    struct Member {
        let id: Session.ID
        /// The worktree folder the session runs in, `nil` for the main checkout.
        var folder: String?
        /// The branch the session counts as being on; `nil` when unknown or detached.
        var branch: String?
        var origin: Session.ID?
        var splitGroup: Int?
        var mentionedTickets: [String] = []
        var override: TaskOverride?
    }

    static let trunkBranches: Set<String> = [
        "main", "master", "develop", "development", "dev", "trunk", "HEAD",
    ]

    static func layout(
        members: [Member],
        facts: TaskFacts = .none,
        pattern: TaskTicketPattern = TaskTicketPattern(),
        isTrunk: (String) -> Bool = { trunkBranches.contains($0) }
    ) -> TaskLayout {
        var graph = Graph()
        let byID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func usableBranch(_ member: Member) -> String? {
            guard let branch = member.branch, !branch.isEmpty, !isTrunk(branch) else { return nil }
            return branch
        }

        // Every session's own nodes, whether or not it ends up following an
        // origin: a branch nobody sits on never surfaces as a task anyway.
        func ownNode(_ member: Member) -> String? {
            let branchNode = usableBranch(member).map { "branch:\($0)" }
            if let folder = member.folder {
                let folderNode = "folder:\(folder)"
                graph.add(folderNode, reason: .worktree((folder as NSString).lastPathComponent))
                if let branchNode { graph.union(folderNode, branchNode) }
                return folderNode
            }
            return branchNode
        }
        var own: [Session.ID: String] = [:]
        for member in members where member.override == nil {
            if let branch = usableBranch(member) {
                graph.add("branch:\(branch)", reason: .branch(branch))
                for ticket in pattern.identifiers(inBranch: branch) {
                    graph.add("ticket:\(ticket)")
                    graph.union("branch:\(branch)", "ticket:\(ticket)",
                                reason: .ticketInBranch(ticket: ticket, branch: branch))
                }
            }
            if let node = ownNode(member) { own[member.id] = node }
        }

        let branchesInUse = Set(members.compactMap(usableBranch))
        for ticket in facts.tickets {
            guard let branch = ticket.branchName, branchesInUse.contains(branch) else { continue }
            graph.add("ticket:\(ticket.identifier)")
            graph.union("branch:\(branch)", "ticket:\(ticket.identifier)",
                        reason: .ticketBranch(ticket: ticket.identifier, branch: branch))
        }
        for pullRequest in facts.pullRequests where branchesInUse.contains(pullRequest.branch) {
            let node = "pr:\(pullRequest.number)"
            graph.add(node)
            graph.union("branch:\(pullRequest.branch)", node,
                        reason: .pullRequest(number: pullRequest.number, branch: pullRequest.branch))
            for ticket in pattern.identifiers(inText: pullRequest.title) {
                graph.add("ticket:\(ticket)")
                graph.union(node, "ticket:\(ticket)",
                            reason: .ticketInPullRequest(ticket: ticket, number: pullRequest.number))
            }
        }

        // A session opened from another goes where that one goes. The chain
        // stops at a session moved by hand — its move is the decision — and at
        // an origin that has since closed.
        func root(of id: Session.ID) -> Session.ID {
            var current = id
            var seen: Set<Session.ID> = [id]
            while let member = byID[current], member.override == nil,
                  let origin = member.origin, byID[origin] != nil,
                  seen.insert(origin).inserted {
                current = origin
            }
            return current
        }
        let roots = Dictionary(members.map { ($0.id, root(of: $0.id)) },
                               uniquingKeysWith: { first, _ in first })
        let rootIDs = members.map(\.id).filter { roots[$0] == $0 }

        var placed: [Session.ID: String] = [:]
        var excluded: Set<Session.ID> = []
        for id in rootIDs {
            guard let member = byID[id] else { continue }
            switch member.override {
            case .excluded:
                excluded.insert(id)
            case .task(let node):
                graph.add(node, reason: .moved)
                placed[id] = node
            case nil:
                if let node = own[id] { placed[id] = node }
            }
        }

        func placeBySplitGroup() {
            for id in rootIDs where placed[id] == nil && !excluded.contains(id) {
                guard let group = byID[id]?.splitGroup else { continue }
                let mate = members.first { other in
                    other.splitGroup == group && other.id != id
                        && roots[other.id].flatMap { placed[$0] } != nil
                }
                if let mate, let mateRoot = roots[mate.id] { placed[id] = placed[mateRoot] }
            }
        }
        placeBySplitGroup()
        for id in rootIDs where placed[id] == nil && !excluded.contains(id) {
            let mentions = members.filter { roots[$0.id] == id }.flatMap(\.mentionedTickets)
            guard let first = mentions.first else { continue }
            let known = mentions.first { graph.contains("ticket:\($0)") } ?? first
            graph.add("ticket:\(known)", reason: .mentioned(known))
            placed[id] = "ticket:\(known)"
        }
        placeBySplitGroup()

        // Components that hold a session become tasks, ordered by where their
        // first session sits in the roster so the tree keeps the user's order.
        // A session moved in by hand doesn't count toward that place: moving an
        // old shell into a task must not lift the whole task up the list.
        var sessionsByComponent: [String: [Session.ID]] = [:]
        var position: [String: (own: Int?, any: Int)] = [:]
        var loose: [Session.ID] = []
        for (index, member) in members.enumerated() {
            guard let rootID = roots[member.id], let node = placed[rootID] else {
                loose.append(member.id)
                continue
            }
            let component = graph.find(node)
            sessionsByComponent[component, default: []].append(member.id)
            let movedByHand = byID[rootID]?.override != nil
            var place = position[component] ?? (own: nil, any: index)
            if !movedByHand, place.own == nil { place.own = index }
            position[component] = place
        }
        let componentOrder = position.keys.sorted { a, b in
            let left = position[a].map { $0.own ?? $0.any } ?? 0
            let right = position[b].map { $0.own ?? $0.any } ?? 0
            return left < right
        }

        let ticketFacts = Dictionary(facts.tickets.map { ($0.identifier, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let pullRequestFacts = Dictionary(facts.pullRequests.map { ($0.number, $0) },
                                          uniquingKeysWith: { first, _ in first })
        let groups = componentOrder.compactMap { component -> TaskGroup? in
            guard let sessionIDs = sessionsByComponent[component] else { return nil }
            let nodes = graph.members(of: component)
            func values(_ prefix: String) -> [String] {
                nodes.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            }
            let tickets = values("ticket:")
            let pullRequests = values("pr:").compactMap(Int.init).compactMap { pullRequestFacts[$0] }
            let title = tickets.lazy.compactMap { ticketFacts[$0]?.title }.first
                ?? pullRequests.first?.title
            let finishedTickets = tickets.compactMap { ticketFacts[$0]?.isFinished }
            let finishedPullRequests = pullRequests.map(\.isFinished)
            let verdicts = finishedTickets + finishedPullRequests
            let id = ["folder:", "branch:", "pr:", "ticket:"].lazy
                .compactMap { prefix in nodes.first { $0.hasPrefix(prefix) } }
                .first ?? component
            return TaskGroup(
                id: id,
                tickets: tickets,
                branches: values("branch:"),
                folders: values("folder:"),
                pullRequests: pullRequests,
                title: title,
                ticketURL: tickets.lazy.compactMap { ticketFacts[$0]?.url }.first,
                isFinished: !verdicts.isEmpty && verdicts.allSatisfy { $0 },
                sessionIDs: sessionIDs,
                reasons: graph.reasons(of: component))
        }
        // Finished work sinks below the work still going, each half in roster order.
        return TaskLayout(groups: groups.filter { !$0.isFinished } + groups.filter(\.isFinished),
                          loose: loose)
    }

    /// Union-find over node names, remembering insertion order (so a task lists
    /// its branches and tickets in the order they were found) and why each node
    /// or edge is there.
    private struct Graph {
        private var parent: [String: String] = [:]
        private var order: [String] = []
        private var nodeReasons: [String: [TaskReason]] = [:]

        func contains(_ node: String) -> Bool { parent[node] != nil }

        mutating func add(_ node: String, reason: TaskReason? = nil) {
            if parent[node] == nil {
                parent[node] = node
                order.append(node)
            }
            if let reason { note(reason, on: node) }
        }

        mutating func union(_ a: String, _ b: String, reason: TaskReason? = nil) {
            add(a)
            add(b)
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[rootB] = rootA }
            if let reason { note(reason, on: a) }
        }

        func find(_ node: String) -> String {
            var current = node
            while let next = parent[current], next != current { current = next }
            return current
        }

        func members(of component: String) -> [String] {
            order.filter { find($0) == component }
        }

        func reasons(of component: String) -> [TaskReason] {
            var seen = Set<TaskReason>()
            return members(of: component)
                .flatMap { nodeReasons[$0] ?? [] }
                .filter { seen.insert($0).inserted }
        }

        private mutating func note(_ reason: TaskReason, on node: String) {
            if nodeReasons[node]?.contains(reason) != true {
                nodeReasons[node, default: []].append(reason)
            }
        }
    }
}
