import Foundation

// MARK: - GitHub provider (REST, read)

/// The GitHub conformance, over the REST API with a bare `URLSession` — no SDK,
/// matching `UsageMonitor`'s API-client shape. One `/issues` request serves both
/// kinds: GitHub models a pull request as an issue with a `pull_request` key
/// (plus `draft` / `merged_at` for the PR-only states), so the kind filter is
/// applied client-side over a single fetch.
struct GitHubIssueProvider: IssueProvider {
    let id = IssueProviderID.github
    let capabilities = IssueCapabilities(pullRequests: true)

    /// The server and credential every request goes to.
    let connection: GitHubConnection

    enum APIError: LocalizedError {
        case status(Int)
        /// A 403/429 that is GitHub throttling, not an access denial — kept distinct from
        /// `.status(403)` so the pane offers "wait and retry" rather than the reconnect/grant-org
        /// recovery, which can't fix a rate limit.
        case rateLimited
        case decoding

        var errorDescription: String? {
            switch self {
            case .status(401): return "GitHub rejected the token. Reconnect from the zero state."
            case .status(403): return "GitHub denied the request — the token may lack access to this repository."
            case .status(404): return "GitHub can’t find this repository with the connected account."
            case .status(let code): return "GitHub replied with HTTP \(code)."
            case .rateLimited: return "GitHub’s rate limit is exhausted. Wait a moment and try again."
            case .decoding: return "GitHub returned an unexpected reply."
            }
        }
    }

    func issues(in container: IssueContainer, query: IssueQuery) async throws -> [IssueSummary] {
        if query.kind == .pullRequest { return try await pullRequests(in: container, query: query) }
        var components = URLComponents(string: "\(connection.apiBase)/repos/\(container.id)/issues")!
        var items = [
            URLQueryItem(name: "state", value: query.openOnly ? "open" : "all"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        if query.assignedToMe, let login = try await login() {
            items.append(URLQueryItem(name: "assignee", value: login))
        }
        if !query.labels.isEmpty {
            // Comma-joined = AND on this endpoint, matching GitHub's own filter.
            items.append(URLQueryItem(name: "labels", value: query.labels.sorted().joined(separator: ",")))
        }
        components.queryItems = items
        let raw: [RawIssue] = try await get(components.url!)
        return raw
            .filter { $0.pullRequest == nil }
            .map { $0.summary() }
    }

    /// Pull requests come from `/pulls`, not `/issues`: on `/issues` they compete with
    /// issues for the 100 rows, and its `assignee` filter misses the pull requests that
    /// are someone's, since pull requests are rarely assigned. `/pulls` filters neither
    /// assignee nor labels, so both apply here, over the rows it returns. The ones
    /// awaiting your review lead the list and are left out of the rest.
    private func pullRequests(in container: IssueContainer, query: IssueQuery) async throws -> [IssueSummary] {
        var components = URLComponents(string: "\(connection.apiBase)/repos/\(container.id)/pulls")!
        components.queryItems = [
            URLQueryItem(name: "state", value: query.openOnly ? "open" : "all"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        async let listing: [RawPullRequestListing] = get(components.url!)
        async let requested: [IssueSummary] = query.toReview
            ? reviewRequests(in: container, labels: query.labels) : []
        let viewer: String? = query.assignedToMe ? try await login() ?? "" : nil
        let awaiting = try await requested
        let awaitingNumbers = Set(awaiting.map(\.number))
        return try await awaiting + listing
            .filter { !awaitingNumbers.contains($0.number) && $0.matches(labels: query.labels, viewer: viewer) }
            .map { $0.summary() }
    }

    /// Open pull requests with your review pending. Search's `review-requested:@me`
    /// covers a request made of a team you're on, which the `/pulls` rows can't
    /// answer: listing your teams needs `read:org`, beyond the `repo` scope fyolo
    /// asks for. GitHub drops the request once the review is in, so a reviewed pull
    /// request leaves this list until someone asks again.
    private func reviewRequests(in container: IssueContainer, labels: Set<String>) async throws -> [IssueSummary] {
        struct SearchResult: Decodable { let items: [RawIssue] }
        var components = URLComponents(string: "\(connection.apiBase)/search/issues")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "repo:\(container.id) is:pr is:open review-requested:@me"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        guard let url = components?.url else { return [] }
        let result: SearchResult = try await get(url)
        return result.items
            .map { $0.summary() }
            .filter { labels.isSubset(of: $0.labels.map(\.name)) }
            .map { item in
                var item = item
                item.awaitsYourReview = true
                return item
            }
    }

    func detail(_ number: Int, in container: IssueContainer) async throws -> IssueDetail {
        let base = "\(connection.apiBase)/repos/\(container.id)/issues/\(number)"
        async let rawIssue: RawIssue = get(URL(string: base)!)
        async let rawComments: [RawComment] = get(URL(string: "\(base)/comments?per_page=100")!)
        let (issue, comments) = try await (rawIssue, rawComments)
        return IssueDetail(
            summary: issue.summary(),
            bodyMarkdown: issue.body ?? "",
            authorAvatarURL: issue.user?.avatarUrl,
            createdAt: issue.createdAt,
            comments: comments.map {
                IssueComment(
                    id: $0.id,
                    author: $0.user?.login ?? "ghost",
                    avatarURL: $0.user?.avatarUrl,
                    createdAt: $0.createdAt,
                    bodyMarkdown: $0.body ?? ""
                )
            }
        )
    }

    /// The repo's label set, for the filter menu. (Becomes the protocol's
    /// `availableLabels` when the write milestone lands — it's already needed
    /// read-only here.)
    func availableLabels(in container: IssueContainer) async throws -> [IssueLabel] {
        struct RawLabel: Decodable {
            let name: String
            let color: String?
        }
        let raw: [RawLabel] = try await get(
            URL(string: "\(connection.apiBase)/repos/\(container.id)/labels?per_page=100")!)
        return raw.map { IssueLabel(name: $0.name, colorHex: $0.color ?? "") }
    }

    /// The repository `slug` was forked from, or `nil` when it isn't a fork. The
    /// half of the fork problem no git remote can answer: `git clone <my-fork>`
    /// leaves a checkout whose only remote is the fork, and GitHub's own `parent`
    /// is then the sole record of where the issues actually live. Discovery only —
    /// fyolo surfaces the parent as a choice and never writes it back as a remote.
    func forkParent(of slug: String) async throws -> String? {
        struct RawRepository: Decodable {
            struct Parent: Decodable { let fullName: String }
            let fork: Bool
            let parent: Parent?
        }
        guard let url = URL(string: "\(connection.apiBase)/repos/\(slug)") else { return nil }
        let raw: RawRepository = try await get(url)
        guard raw.fork else { return nil }
        return raw.parent?.fullName
    }

    // MARK: Pull-request extras (GitHub-specific, outside the tracker protocol)

    /// The PR's changed files as `GitChange` rows (the git pane's own model) *with the
    /// diff inline*: the `/pulls/{n}/files` response already carries each file's unified
    /// `patch`, so the Files tab renders straight from this one call — no `git fetch` of
    /// the PR refs, no per-file `git diff`, and it works for cross-fork PRs with nothing
    /// checked out locally. GitHub omits `patch` for binaries and diffs too large to
    /// inline; those arrive as `nil` and the UI shows a note instead.
    func pullRequestFiles(_ number: Int, in container: IssueContainer) async throws -> [PullRequestFile] {
        struct RawFile: Decodable {
            let filename: String
            let status: String
            let additions: Int
            let deletions: Int
            let previousFilename: String?
            let patch: String?
            let contentsUrl: String?
        }
        let raw: [RawFile] = try await get(
            URL(string: "\(connection.apiBase)/repos/\(container.id)/pulls/\(number)/files?per_page=100")!)
        return raw.map { file in
            let status: GitFileStatus
            switch file.status {
            case "added": status = .added
            case "removed": status = .deleted
            case "renamed": status = .renamed
            case "copied": status = .copied
            default: status = .modified
            }
            var change = GitChange(path: file.filename, status: status, isUntracked: false)
            change.additions = file.additions
            change.deletions = file.deletions
            change.originalPath = file.previousFilename
            // No `patch` on a binary file; GitHub also drops it past its inline-size cap.
            change.isBinary = file.patch == nil && file.additions == 0 && file.deletions == 0
            return PullRequestFile(change: change, patch: file.patch,
                                   contentsURL: file.contentsUrl.flatMap(URL.init(string:)))
        }
    }

    /// One PR file's text at the PR head, for expanding the context its patch left out.
    /// `contents_url` is already pinned to the head sha, and the raw media type returns the
    /// file itself rather than base64 in JSON — so this stays one request with no decode.
    /// Binary or over-large files come back as something other than UTF-8 text and are
    /// reported as missing, leaving the diff's bands inert.
    func fileText(at url: URL) async throws -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.status(http.statusCode)
        }
        return String(data: data, encoding: .utf8)
    }

    /// The connected account's login, fetched once per app run — the `assignee`
    /// filter needs a username, not a token.
    private func login() async throws -> String? {
        if let cached = Self.cachedLogin, cached.token == connection.token { return cached.login }
        let login = try await account()
        Self.cachedLogin = (connection.token, login)
        return login
    }

    /// Keyed by token, so connecting as someone else never answers with the
    /// previous account's login.
    private nonisolated(unsafe) static var cachedLogin: (token: String, login: String)?

    /// The login this connection signs in as — a live round trip, which is what
    /// makes it the check that a pasted token and host actually work.
    func account() async throws -> String {
        struct RawUser: Decodable { let login: String }
        guard let url = URL(string: "\(connection.apiBase)/user") else { throw APIError.decoding }
        let user: RawUser = try await get(url)
        return user.login
    }

    /// Every repository the account can clone — its own, its collaborations, and
    /// its organizations' — most recently pushed first, which is the order someone
    /// picking a project to work on wants. Paged until GitHub runs out, capped so an
    /// account in a huge organization still answers in a few requests; the welcome
    /// page's search covers what the cap leaves out of view.
    func repositories() async throws -> [GitHubRepository] {
        let pageSize = 100
        var repositories: [GitHubRepository] = []
        for page in 1...5 {
            var components = URLComponents(string: "\(connection.apiBase)/user/repos")!
            components.queryItems = [
                URLQueryItem(name: "sort", value: "pushed"),
                URLQueryItem(name: "per_page", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            let batch: [GitHubRepository] = try await get(components.url!)
            repositories += batch
            if batch.count < pageSize { break }
        }
        return repositories
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // GitHub signals throttling with a 403 or 429 carrying an exhausted primary-limit
            // header (`x-ratelimit-remaining: 0`) or a secondary-limit `retry-after`. Classify
            // those as `.rateLimited` so a 403 that is really "no access to this repo" stays the
            // only case that offers the reconnect/grant-org recovery.
            if http.statusCode == 403 || http.statusCode == 429 {
                let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
                let retryAfter = http.value(forHTTPHeaderField: "retry-after")
                if remaining == "0" || retryAfter != nil {
                    throw APIError.rateLimited
                }
            }
            throw APIError.status(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Log.issues.error("decode failed for \(url.path, privacy: .public): \(error, privacy: .public)")
            throw APIError.decoding
        }
    }
}

// MARK: - Wire types

private struct RawIssue: Decodable {
    struct RawLabel: Decodable {
        let name: String
        let color: String?
    }
    struct RawUser: Decodable {
        let login: String
        let avatarUrl: URL?
    }
    /// Present on PR items. `mergedAt` marks a closed PR as merged.
    struct RawPullRequest: Decodable {
        let mergedAt: Date?
    }

    let number: Int
    let title: String
    let state: String
    let body: String?
    let labels: [RawLabel]
    let user: RawUser?
    let createdAt: Date
    let updatedAt: Date
    let htmlUrl: URL?
    let draft: Bool?
    let pullRequest: RawPullRequest?

    func summary() -> IssueSummary {
        let kind: IssueKind = pullRequest == nil ? .issue : .pullRequest
        let itemState: IssueItemState
        if state == "open" {
            itemState = (kind == .pullRequest && draft == true) ? .draft : .open
        } else {
            itemState = pullRequest?.mergedAt != nil ? .merged : .closed
        }
        return IssueSummary(
            number: number,
            identifier: "#\(number)",
            title: title,
            kind: kind,
            state: itemState,
            labels: labels.map { IssueLabel(name: $0.name, colorHex: $0.color ?? "") },
            author: user?.login ?? "ghost",
            updatedAt: updatedAt,
            url: htmlUrl
        )
    }
}

/// One row of `/pulls`, which spells a merge as a top-level `merged_at` rather than
/// `/issues`' nested `pull_request`.
struct RawPullRequestListing: Decodable {
    struct RawLabel: Decodable { let name: String; let color: String? }
    struct RawUser: Decodable { let login: String }

    let number: Int
    let title: String
    let state: String
    let draft: Bool?
    let mergedAt: Date?
    let labels: [RawLabel]
    let user: RawUser?
    let assignees: [RawUser]?
    let requestedReviewers: [RawUser]?
    let updatedAt: Date
    let htmlUrl: URL?

    /// "Mine" for a pull request: the viewer opened it, is assigned to it, or is asked to
    /// review it. A `nil` viewer means no such filter. Labels combine as AND, like GitHub's.
    func matches(labels wanted: Set<String>, viewer: String?) -> Bool {
        guard wanted.isSubset(of: labels.map(\.name)) else { return false }
        guard let viewer else { return true }
        let people = [user].compactMap { $0 } + (assignees ?? []) + (requestedReviewers ?? [])
        return people.contains { $0.login.caseInsensitiveCompare(viewer) == .orderedSame }
    }

    func summary() -> IssueSummary {
        let itemState: IssueItemState
        if state == "open" {
            itemState = draft == true ? .draft : .open
        } else {
            itemState = mergedAt != nil ? .merged : .closed
        }
        return IssueSummary(
            number: number,
            identifier: "#\(number)",
            title: title,
            kind: .pullRequest,
            state: itemState,
            labels: labels.map { IssueLabel(name: $0.name, colorHex: $0.color ?? "") },
            author: user?.login ?? "ghost",
            updatedAt: updatedAt,
            url: htmlUrl
        )
    }
}

private struct RawComment: Decodable {
    let id: Int
    let user: RawIssue.RawUser?
    let body: String?
    let createdAt: Date
}

/// A repository the connected account can clone, as `/user/repos` lists it.
struct GitHubRepository: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let isPrivate: Bool
    let cloneUrl: String
    let pushedAt: Date?
    let owner: Owner

    struct Owner: Decodable, Hashable, Sendable {
        let login: String
        let avatarUrl: URL?
    }

    // The decoder converts snake_case first, so these name the converted keys.
    enum CodingKeys: String, CodingKey {
        case id, name, fullName, cloneUrl, pushedAt, owner
        case isPrivate = "private"
    }
}
