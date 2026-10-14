import Foundation
import SwiftUI

// MARK: - Linked pull requests

/// Where a pull request stands, collapsed to the one word a chip has room for.
enum LinkedPullRequestStatus: Hashable, Sendable {
    case merged, closed, draft, failing, pending, inReview, readyToMerge, open

    /// First match wins: an outcome (merged, closed) outranks the work in
    /// progress, and a broken or running check outranks a review verdict —
    /// an approved PR with red checks is not ready to merge.
    init(state: String, isDraft: Bool, checks: String?, reviewDecision: String?, mergeState: String?) {
        switch state {
        case "MERGED": self = .merged
        case "CLOSED": self = .closed
        default:
            if isDraft {
                self = .draft
            } else if checks == "FAILURE" || checks == "ERROR" {
                self = .failing
            } else if checks == "PENDING" || checks == "EXPECTED" {
                self = .pending
            } else if reviewDecision == "REVIEW_REQUIRED" || reviewDecision == "CHANGES_REQUESTED" {
                self = .inReview
            } else if mergeState == "CLEAN" {
                self = .readyToMerge
            } else {
                self = .open
            }
        }
    }

    var label: String {
        switch self {
        case .merged: localized("Merged")
        case .closed: localized("Closed")
        case .draft: localized("Draft")
        case .failing: localized("Checks Failing")
        case .pending: localized("Checks Running")
        case .inReview: localized("In Review")
        case .readyToMerge: localized("Ready to Merge")
        case .open: localized("issue.state.open")
        }
    }

    var tint: Color {
        switch self {
        case .merged: .purple
        case .closed, .failing: .red
        case .draft: .gray
        case .pending: .yellow
        case .inReview: .orange
        case .readyToMerge: .green
        case .open: .blue
        }
    }

    /// The same colors for the detail page's HTML chips.
    var cssClass: String {
        switch self {
        case .merged: "merged"
        case .closed: "closed"
        case .draft: "draft"
        case .failing: "failing"
        case .pending: "pending"
        case .inReview: "review"
        case .readyToMerge: "ready"
        case .open: "open"
        }
    }
}

struct LinkedPullRequest: Hashable, Identifiable, Sendable {
    let number: Int
    let title: String
    let url: URL
    /// `owner/name`, so a PR found in another of the owner's repositories says where it is.
    let repository: String
    let status: LinkedPullRequestStatus

    var id: URL { url }
}

// MARK: - Title matching

/// Finds Linear identifiers in pull request titles. Built from the workspace's
/// real team keys, so only `ENG-123` for a team that exists matches — never
/// `UTF-8`, `ISO-8601` or `RFC-2119`, which a generic `[A-Z]+-\d+` would take.
struct LinearTicketPattern: Sendable {
    private let expression: NSRegularExpression

    init?(teamKeys: [String]) {
        let keys = Set(teamKeys.map { $0.uppercased() }.filter { !$0.isEmpty })
        guard !keys.isEmpty else { return nil }
        // Longest first, so `ENGX` isn't read as `ENG` followed by junk.
        let alternatives = keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = "(?<![A-Za-z0-9])(\(alternatives))-0*(\\d{1,9})(?![0-9])"
        do {
            expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            Log.issues.error("Linear ticket pattern failed to compile: \(error, privacy: .public)")
            return nil
        }
    }

    /// Every identifier in `text`, normalized to Linear's own spelling
    /// (`eng-012` → `ENG-12`), each once, in order of appearance.
    func identifiers(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return expression.matches(in: text, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let numberRange = Range(match.range(at: 2), in: text),
                  let number = Int(text[numberRange])
            else { return nil }
            let identifier = "\(text[keyRange].uppercased())-\(number)"
            return seen.insert(identifier).inserted ? identifier : nil
        }
    }

    /// `identifier → pull requests whose titles name it`, built in one pass. A
    /// title naming two tickets lists the PR under both.
    func index(_ pullRequests: [LinkedPullRequest]) -> [String: [LinkedPullRequest]] {
        var index: [String: [LinkedPullRequest]] = [:]
        for pullRequest in pullRequests {
            for identifier in identifiers(in: pullRequest.title) {
                index[identifier, default: []].append(pullRequest)
            }
        }
        return index
    }
}

// MARK: - GitHub lookups

/// The two GitHub reads behind the chips, both GraphQL so a PR's review and
/// check state arrive with it instead of costing a request each.
struct GitHubPullRequestLookup: Sendable {
    let connection: GitHubConnection

    private static let fields = """
    number title url state isDraft reviewDecision mergeStateStatus
    statusCheckRollup { state }
    repository { nameWithOwner }
    """

    /// The repository's most recently updated pull requests, open or not — the
    /// window the list's chips come from.
    func recent(in slug: String, limit: Int = 100) async throws -> [LinkedPullRequest] {
        struct Reply: Decodable {
            struct Repository: Decodable { let pullRequests: LinearNodes<RawPullRequest> }
            let repository: Repository?
        }
        let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        let document = """
        query($owner: String!, $name: String!, $limit: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequests(first: $limit, orderBy: { field: UPDATED_AT, direction: DESC }) {
              nodes { \(Self.fields) }
            }
          }
        }
        """
        let reply: Reply = try await query(
            document, variables: ["owner": parts[0], "name": parts[1], "limit": min(limit, 100)])
        return reply.repository?.pullRequests.nodes.compactMap(\.linked) ?? []
    }

    /// Pull requests anywhere under `owner` whose title names `identifier` — the
    /// fallback for a ticket whose PR is older than the recent window, or lives in
    /// another of the owner's repositories. Search is fuzzy (it splits `ENG-123`
    /// into words), so the caller re-checks every hit against the pattern.
    func mentioning(_ identifier: String, owner: String) async throws -> [LinkedPullRequest] {
        struct Reply: Decodable {
            struct Search: Decodable { let nodes: [RawPullRequest] }
            let search: Search
        }
        let document = """
        query($query: String!) {
          search(query: $query, type: ISSUE, first: 20) {
            nodes { ... on PullRequest { \(Self.fields) } }
          }
        }
        """
        let search = "\"\(identifier)\" in:title is:pr user:\(owner)"
        let reply: Reply = try await query(document, variables: ["query": search])
        return reply.search.nodes.compactMap(\.linked)
    }

    private func query<T: Decodable>(_ document: String, variables: [String: any Sendable]) async throws -> T {
        guard let url = connection.graphQLURL else { throw GitHubIssueProvider.APIError.decoding }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["query": document, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GitHubIssueProvider.APIError.status(http.statusCode)
        }
        let envelope: GraphQLEnvelope<T>
        do {
            envelope = try JSONDecoder().decode(GraphQLEnvelope<T>.self, from: data)
        } catch {
            Log.issues.error("GitHub pull request lookup decode failed: \(error, privacy: .public)")
            throw GitHubIssueProvider.APIError.decoding
        }
        guard let payload = envelope.data else {
            Log.issues.error("GitHub pull request lookup failed: \(envelope.errors?.first?.message ?? "no data", privacy: .public)")
            throw GitHubIssueProvider.APIError.decoding
        }
        return payload
    }
}

/// A pull request as GraphQL returns it. Every field is optional because a
/// search result that isn't a pull request arrives as an empty object.
private struct RawPullRequest: Decodable, Hashable, Sendable {
    struct Rollup: Decodable, Hashable, Sendable { let state: String? }
    struct Repository: Decodable, Hashable, Sendable { let nameWithOwner: String }

    let number: Int?
    let title: String?
    let url: URL?
    let state: String?
    let isDraft: Bool?
    let reviewDecision: String?
    let mergeStateStatus: String?
    let statusCheckRollup: Rollup?
    let repository: Repository?

    var linked: LinkedPullRequest? {
        guard let number, let title, let url, let state else { return nil }
        return LinkedPullRequest(
            number: number,
            title: title,
            url: url,
            repository: repository?.nameWithOwner ?? "",
            status: LinkedPullRequestStatus(
                state: state,
                isDraft: isDraft ?? false,
                checks: statusCheckRollup?.state,
                reviewDecision: reviewDecision,
                mergeState: mergeStateStatus
            )
        )
    }
}
