import Foundation
import SwiftUI

// MARK: - Models

/// A Linear connection's `{ nodes: [...] }` list shape.
struct LinearNodes<Node: Decodable & Hashable & Sendable>: Decodable, Hashable, Sendable {
    let nodes: [Node]
}

struct LinearTeam: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    /// The identifier prefix: `ENG` in `ENG-123`.
    let key: String
    let name: String
}

struct LinearUser: Decodable, Hashable, Sendable {
    let id: String?
    let displayName: String
    let avatarUrl: String?
}

struct LinearWorkflowState: Decodable, Hashable, Sendable {
    let name: String
    /// `triage`, `backlog`, `unstarted`, `started`, `completed` or `canceled`.
    let type: String
    /// `#rrggbb`.
    let color: String

    var tint: Color { IssueLabel(name: name, colorHex: String(color.drop { $0 == "#" })).color }

    /// Work in motion before work queued, queued before untriaged, untriaged
    /// before the backlog.
    var rank: Int {
        switch type {
        case "started": 0
        case "unstarted": 1
        case "triage": 2
        case "backlog": 3
        default: 4
        }
    }
}

struct LinearLabel: Decodable, Hashable, Sendable {
    let name: String
    let color: String
}

/// Linear's priority: `0` none, then `1` urgent through `4` low.
enum LinearPriority {
    static func rank(_ priority: Double) -> Int {
        let value = Int(priority)
        return (1...4).contains(value) ? value : 5
    }

    static func label(_ priority: Double) -> String {
        switch Int(priority) {
        case 1: localized("Urgent")
        case 2: localized("High")
        case 3: localized("Medium")
        case 4: localized("Low")
        default: localized("No Priority")
        }
    }
}

/// One row of the list.
struct LinearIssue: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let identifier: String
    let title: String
    let priority: Double
    let url: URL
    let updatedAt: Date
    let state: LinearWorkflowState
    let assignee: LinearUser?
    let labels: LinearNodes<LinearLabel>

    func matches(search: String) -> Bool {
        search.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            title.localizedStandardContains(term) || identifier.localizedStandardContains(term)
        }
    }
}

/// Another ticket a detail points at: its parent, a sub-issue, a relation.
struct LinearIssueReference: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let identifier: String
    let title: String
    let state: LinearWorkflowState
}

struct LinearComment: Decodable, Hashable, Identifiable, Sendable {
    struct Bot: Decodable, Hashable, Sendable { let name: String? }

    let id: String
    let body: String
    let createdAt: Date
    let user: LinearUser?
    /// Set for a comment an integration wrote, which has no user.
    let botActor: Bot?

    var author: String { user?.displayName ?? botActor?.name ?? localized("Linear") }
}

struct LinearIssueDetail: Decodable, Hashable, Sendable {
    struct Relation: Decodable, Hashable, Sendable {
        let type: String
        let relatedIssue: LinearIssueReference
    }
    struct InverseRelation: Decodable, Hashable, Sendable {
        let type: String
        let issue: LinearIssueReference
    }

    let id: String
    let identifier: String
    let title: String
    let description: String?
    let priority: Double
    let url: URL
    let createdAt: Date
    let state: LinearWorkflowState
    let assignee: LinearUser?
    let creator: LinearUser?
    let team: LinearTeam
    let labels: LinearNodes<LinearLabel>
    let parent: LinearIssueReference?
    let children: LinearNodes<LinearIssueReference>
    let relations: LinearNodes<Relation>
    let inverseRelations: LinearNodes<InverseRelation>
    let comments: LinearNodes<LinearComment>

    /// The tickets this one points at, grouped the way Linear's own sidebar
    /// reads them. A relation is stored once, on the ticket that made it, so
    /// "blocked by" is the other ticket's `blocks` seen from here.
    var linkedTickets: [(title: String, tickets: [LinearIssueReference])] {
        func outgoing(_ type: String) -> [LinearIssueReference] {
            relations.nodes.filter { $0.type == type }.map(\.relatedIssue)
        }
        func incoming(_ type: String) -> [LinearIssueReference] {
            inverseRelations.nodes.filter { $0.type == type }.map(\.issue)
        }
        let groups: [(String, [LinearIssueReference])] = [
            (localized("Parent"), parent.map { [$0] } ?? []),
            (localized("Sub-Issues"), children.nodes),
            (localized("Blocks"), outgoing("blocks")),
            (localized("Blocked By"), incoming("blocks")),
            (localized("Duplicate Of"), outgoing("duplicate")),
            (localized("Duplicated By"), incoming("duplicate")),
            (localized("Related"), outgoing("related") + incoming("related")
                + outgoing("similar") + incoming("similar")),
        ]
        return groups.filter { !$0.1.isEmpty }.map { (title: $0.0, tickets: $0.1) }
    }

    /// Oldest first, the order a thread is read in.
    var thread: [LinearComment] { comments.nodes.sorted { $0.createdAt < $1.createdAt } }
}

// MARK: - Ordering

enum LinearIssueOrdering {
    /// The viewer's own tickets, then everyone else's, each ordered by priority
    /// (urgent first, none last), then by how far along the work is, then by
    /// most recent change.
    static func split(_ issues: [LinearIssue], viewerID: String?) -> (mine: [LinearIssue], others: [LinearIssue]) {
        let ordered = issues.sorted { left, right in
            let leftPriority = LinearPriority.rank(left.priority)
            let rightPriority = LinearPriority.rank(right.priority)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            if left.state.rank != right.state.rank { return left.state.rank < right.state.rank }
            return left.updatedAt > right.updatedAt
        }
        guard let viewerID else { return ([], ordered) }
        let mine = ordered.filter { $0.assignee?.id == viewerID }
        let others = ordered.filter { $0.assignee?.id != viewerID }
        return (mine, others)
    }
}

// MARK: - Client

/// The `{ data, errors }` reply Linear's and GitHub's GraphQL APIs both answer with.
struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    struct Failure: Decodable {
        struct Extensions: Decodable {
            let code: String?
            let type: String?
        }
        let message: String
        let extensions: Extensions?
    }
    let data: Payload?
    let errors: [Failure]?
}

enum LinearAPIError: LocalizedError {
    case unauthorized
    case rateLimited
    case status(Int)
    case graphQL(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .unauthorized: return localized("Linear no longer accepts this sign-in. Connect again.")
        case .rateLimited: return localized("Linear’s rate limit is exhausted. Wait a moment and try again.")
        case .status(let code): return localized("Linear replied with HTTP \(code).")
        case .graphQL(let message): return message
        case .decoding: return localized("Linear returned an unexpected reply.")
        }
    }
}

/// Linear's GraphQL API over a bare `URLSession`, the same no-SDK shape as the
/// GitHub provider. Read only.
struct LinearClient: Sendable {
    let connection: LinearConnection

    struct Viewer: Sendable {
        let id: String
        let teams: [LinearTeam]
    }

    func viewer() async throws -> Viewer {
        struct Reply: Decodable {
            struct User: Decodable { let id: String }
            let viewer: User
            let teams: LinearNodes<LinearTeam>
        }
        let reply: Reply = try await query(
            "query { viewer { id } teams(first: 250) { nodes { id key name } } }")
        return Viewer(
            id: reply.viewer.id,
            teams: reply.teams.nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// The team's tickets that are still open — every state but done and
    /// canceled — most recently changed first, up to `limit`.
    func openIssues(teamID: String, limit: Int = 300) async throws -> [LinearIssue] {
        struct Reply: Decodable {
            struct Team: Decodable {
                struct Page: Decodable {
                    struct Info: Decodable {
                        let hasNextPage: Bool
                        let endCursor: String?
                    }
                    let nodes: [LinearIssue]
                    let pageInfo: Info
                }
                let issues: Page
            }
            let team: Team
        }
        let document = """
        query($team: String!, $after: String) {
          team(id: $team) {
            issues(first: 100, after: $after, orderBy: updatedAt,
                   filter: { state: { type: { nin: ["completed", "canceled"] } } }) {
              nodes {
                id identifier title priority url updatedAt
                state { name type color }
                assignee { id displayName avatarUrl }
                labels { nodes { name color } }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
        """
        var issues: [LinearIssue] = []
        var cursor: String?
        repeat {
            var variables = ["team": teamID]
            if let cursor { variables["after"] = cursor }
            let reply: Reply = try await query(document, variables: variables)
            issues += reply.team.issues.nodes
            cursor = reply.team.issues.pageInfo.hasNextPage ? reply.team.issues.pageInfo.endCursor : nil
        } while cursor != nil && issues.count < limit
        return issues
    }

    /// One ticket in full. `id` may be the UUID or the `ENG-123` identifier;
    /// Linear resolves either.
    func issue(_ id: String) async throws -> LinearIssueDetail {
        struct Reply: Decodable { let issue: LinearIssueDetail }
        let reference = "id identifier title state { name type color }"
        let document = """
        query($id: String!) {
          issue(id: $id) {
            id identifier title description priority url createdAt
            state { name type color }
            assignee { id displayName avatarUrl }
            creator { id displayName avatarUrl }
            team { id key name }
            labels { nodes { name color } }
            parent { \(reference) }
            children(first: 50) { nodes { \(reference) } }
            relations(first: 50) { nodes { type relatedIssue { \(reference) } } }
            inverseRelations(first: 50) { nodes { type issue { \(reference) } } }
            comments(first: 100) {
              nodes { id body createdAt user { id displayName avatarUrl } botActor { name } }
            }
          }
        }
        """
        let reply: Reply = try await query(document, variables: ["id": id])
        return reply.issue
    }

    // MARK: Transport

    private func query<T: Decodable>(_ document: String, variables: [String: String] = [:]) async throws -> T {
        let usable = try await LinearTokenRenewer.shared.usable(connection)
        do {
            return try await send(document, variables: variables, as: usable)
        } catch LinearAPIError.unauthorized where usable.source == .oauth {
            // A token can be revoked or expire early; one renewal is worth trying
            // before the pane asks the user to connect again.
            let renewed = try await LinearTokenRenewer.shared.usable(usable, force: true)
            return try await send(document, variables: variables, as: renewed)
        }
    }

    private func send<T: Decodable>(
        _ document: String, variables: [String: String], as connection: LinearConnection
    ) async throws -> T {
        guard let url = URL(string: "https://api.linear.app/graphql") else { throw LinearAPIError.decoding }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["query": document, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 401 { throw LinearAPIError.unauthorized }
        if status == 429 { throw LinearAPIError.rateLimited }

        let envelope: GraphQLEnvelope<T>
        do {
            envelope = try Self.decoder.decode(GraphQLEnvelope<T>.self, from: data)
        } catch {
            if !(200...299).contains(status) { throw LinearAPIError.status(status) }
            Log.issues.error("Linear decode failed: \(error, privacy: .public)")
            throw LinearAPIError.decoding
        }
        // Linear reports auth and throttling as GraphQL errors, often under a 400.
        if let failure = envelope.errors?.first {
            let code = failure.extensions?.code?.uppercased() ?? ""
            if code == "AUTHENTICATION_ERROR" || failure.extensions?.type == "authentication error" {
                throw LinearAPIError.unauthorized
            }
            if code == "RATELIMITED" { throw LinearAPIError.rateLimited }
            if envelope.data == nil { throw LinearAPIError.graphQL(failure.message) }
        }
        guard let payload = envelope.data else { throw LinearAPIError.status(status) }
        return payload
    }

    /// Linear writes timestamps with milliseconds, which `.iso8601` rejects.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unreadable date \(text)"))
        }
        return decoder
    }()
}
