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

    /// What a search for `identifiers` found, filed under each identifier asked
    /// about — and only those, since a fuzzy hit can name a ticket nobody asked
    /// for. A ticket with no pull request maps to an empty list, which records
    /// that it was looked up.
    func index(_ pullRequests: [LinkedPullRequest], for identifiers: [String]) -> [String: [LinkedPullRequest]] {
        let found = index(pullRequests)
        return Dictionary(identifiers.map { ($0, found[$0] ?? []) }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - GitHub lookups

/// The GitHub read behind the chips: a title search, in GraphQL so each PR's
/// review and check state arrive with it instead of costing a request each.
struct GitHubPullRequestLookup: Sendable {
    let connection: GitHubConnection

    /// How many identifiers share one search. GitHub's issue search allows five
    /// `OR`s; a sixth makes it answer with nothing at all rather than an error.
    static let identifiersPerSearch = 6

    private static let fields = """
    number title url state isDraft reviewDecision mergeStateStatus
    statusCheckRollup { state }
    repository { nameWithOwner }
    """

    /// The search strings for `identifiers`, six to a query, each scoped to the
    /// pull requests of `owner`'s account. Pure, so the batching and the scope
    /// can be pinned in tests.
    static func searchQueries(for identifiers: [String], owner: String) -> [String] {
        stride(from: 0, to: identifiers.count, by: identifiersPerSearch).map { start in
            let batch = identifiers[start..<min(start + identifiersPerSearch, identifiers.count)]
            let terms = batch.map { "\"\($0)\"" }.joined(separator: " OR ")
            return "is:pr user:\(owner) in:title \(terms)"
        }
    }

    /// Pull requests anywhere under `owner` whose titles name any of
    /// `identifiers` — one request, holding one aliased search per batch of six.
    /// Plain `ISSUE` search on purpose: `ISSUE_ADVANCED` lets `OR` escape the
    /// `user:` scope and answers with other people's repositories. Search matches
    /// words rather than tokens (`ENG-12` is `ENG` near `12`), so the caller
    /// re-checks every title against the ticket pattern.
    func mentioning(_ identifiers: [String], owner: String) async throws -> [LinkedPullRequest] {
        struct Search: Decodable { let nodes: [RawPullRequest] }
        let queries = Self.searchQueries(for: identifiers, owner: owner)
        guard !queries.isEmpty else { return [] }
        let declarations = queries.indices.map { "$q\($0): String!" }.joined(separator: ", ")
        let searches = queries.indices.map { index in
            "s\(index): search(query: $q\(index), type: ISSUE, first: 50) { nodes { ... on PullRequest { \(Self.fields) } } }"
        }.joined(separator: "\n")
        var variables: [String: any Sendable] = [:]
        for (index, query) in queries.enumerated() { variables["q\(index)"] = query }
        let reply: [String: Search] = try await connection.graphQL(
            "query(\(declarations)) {\n\(searches)\n}", variables: variables)
        // A PR naming tickets from two batches comes back twice.
        var seen = Set<URL>()
        return reply.keys.sorted().flatMap { reply[$0]?.nodes ?? [] }
            .compactMap(\.linked)
            .filter { seen.insert($0.url).inserted }
    }

    /// How many branches share one request — enough for every branch a project
    /// has sessions on, small enough that one reply stays quick.
    static let branchesPerRequest = 25

    /// The pull request each of `branches` is the head of in `slug`
    /// (`owner/name`): the open one when there is one, else the most recently
    /// updated. A branch name reused after an old pull request closed would
    /// otherwise bring that pull request's tickets into today's work.
    func headedBy(_ branches: [String], in slug: String) async throws -> [String: LinkedPullRequest] {
        struct Page: Decodable { let nodes: [RawPullRequest] }
        struct Reply: Decodable { let repository: [String: Page]? }
        let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !branches.isEmpty else { return [:] }
        let asked = Array(branches.prefix(Self.branchesPerRequest))
        let declarations = (["$owner: String!", "$name: String!"]
            + asked.indices.map { "$b\($0): String!" }).joined(separator: ", ")
        let lookups = asked.indices.map { index in
            "b\(index): pullRequests(headRefName: $b\(index), first: 5, "
                + "orderBy: { field: UPDATED_AT, direction: DESC }) { nodes { \(Self.fields) } }"
        }.joined(separator: "\n")
        var variables: [String: any Sendable] = ["owner": parts[0], "name": parts[1]]
        for (index, branch) in asked.enumerated() { variables["b\(index)"] = branch }
        let reply: Reply = try await connection.graphQL(
            "query(\(declarations)) {\nrepository(owner: $owner, name: $name) {\n\(lookups)\n}\n}",
            variables: variables)
        var headed: [String: LinkedPullRequest] = [:]
        for (index, branch) in asked.enumerated() {
            let candidates = (reply.repository?["b\(index)"]?.nodes ?? []).compactMap(\.linked)
            let open = candidates.first { $0.status != .merged && $0.status != .closed }
            if let chosen = open ?? candidates.first { headed[branch] = chosen }
        }
        return headed
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
