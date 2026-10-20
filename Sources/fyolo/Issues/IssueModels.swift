import Foundation
import SwiftUI

// MARK: - Issue tracker models

/// A built-in issue tracker backend. Linear/Jira arrive as further cases +
/// `IssueProvider` conformances (see docs/design/20260726-issue-tracker-integration.md);
/// the UI never branches on this — it reads `IssueCapabilities` instead.
enum IssueProviderID: String, Sendable {
    case github
}

/// What a provider can do, so the UI shrinks to the backend's real surface
/// instead of branching per provider: Linear has no GitHub-style emoji
/// reactions and no pull requests, so those controls disappear for it.
struct IssueCapabilities: Sendable {
    /// The tracker distinguishes pull requests from issues — shows the
    /// Issues / Pull Requests kind switch.
    let pullRequests: Bool
}

/// Which kind of item the list is showing. On GitHub a PR *is* an issue with
/// extra fields (one `/issues` endpoint serves both), so the kind is a filter
/// over one model, not a second model.
enum IssueKind: Hashable, Sendable {
    case issue, pullRequest
}

/// An item's lifecycle state, normalized across kinds. `merged` and `draft`
/// exist only for pull requests.
enum IssueItemState: Hashable, Sendable {
    case open, closed, merged, draft

    /// The state color, following GitHub's own convention: open green; closed
    /// issue and merged PR purple (done-states); a closed *unmerged* PR red —
    /// rejected is the opposite outcome of merged, so they must not share a
    /// color; draft grey.
    func tint(for kind: IssueKind) -> Color {
        switch self {
        case .open: return .green
        case .closed: return kind == .pullRequest ? .red : .purple
        case .merged: return .purple
        case .draft: return .gray
        }
    }

    /// The state glyph: GitHub's own Octicon for this lifecycle state, so a row
    /// shows the exact mark users read on github.com. Shape carries the state on
    /// its own — open issue and closed PR are a red/green pair that colorblind
    /// users can't separate by hue, but the shapes stay distinct.
    func octicon(for kind: IssueKind) -> StateOcticon {
        switch self {
        case .open: return kind == .pullRequest ? .pullOpen : .issueOpened
        case .closed: return kind == .pullRequest ? .pullClosed : .issueClosed
        case .merged: return .pullMerged
        case .draft: return .pullDraft
        }
    }

    var label: String {
        switch self {
        // Explicit key: the English word "Open" is already the verb key (打开),
        // and the state reads 开放 — the catalog disambiguates by key, not context.
        case .open: return localized("issue.state.open")
        case .closed: return localized("Closed")
        case .merged: return localized("Merged")
        case .draft: return localized("Draft")
        }
    }
}

/// What an open pull request is waiting on, read from GitHub's own merge signals
/// rather than guessed from the timeline. The cases are what someone has to do
/// next, so the list can lead with the pull requests that need a hand on them.
enum PullRequestStatus: Hashable, Sendable {
    case readyToMerge
    case conflicts
    case checksFailing
    case changesRequested
    /// Unresolved review threads a bot opened — Copilot's code review, or an AI
    /// reviewer app. They block nothing, so GitHub's review decision never shows
    /// them; `reviewer` is the bot with the most of them.
    case botFeedback(reviewer: String, comments: Int)
    case checksRunning
    case awaitingReview
    /// Open with no signal that says more — mergeability not computed yet, or a
    /// branch rule this reading doesn't model.
    case open

    /// The merge-state inputs, as GitHub's GraphQL spells them.
    struct Signals: Sendable {
        var mergeable: String?
        var reviewDecision: String?
        var checks: String?
        var pendingReviewRequests = 0
        var humanRequestedChanges = false
        var botChangeRequesters: [String] = []
        /// The bot that opened each unresolved, current review thread.
        var botThreadAuthors: [String] = []
    }

    /// First match wins, in the order the fixes have to happen: a conflict or a red
    /// check is broken whatever the reviewers say, and a person's verdict outranks
    /// a bot's. Ready means mergeable, green (or no checks at all) and nothing asked
    /// of a reviewer — read from these rather than GitHub's `mergeStateStatus`,
    /// which costs a quarter second per pull request on every request, and then
    /// confirmed by it for the few that read ready (`confirmed(byMergeState:)`).
    init(_ signals: Signals) {
        let botAuthors = signals.botThreadAuthors + signals.botChangeRequesters
        if signals.mergeable == "CONFLICTING" {
            self = .conflicts
        } else if signals.checks == "FAILURE" || signals.checks == "ERROR" {
            self = .checksFailing
        } else if signals.humanRequestedChanges {
            self = .changesRequested
        } else if !botAuthors.isEmpty {
            let counts = Dictionary(botAuthors.map { ($0, 1) }, uniquingKeysWith: +)
            let reviewer = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
            self = .botFeedback(reviewer: reviewer, comments: signals.botThreadAuthors.count)
        } else if signals.checks == "PENDING" || signals.checks == "EXPECTED" {
            self = .checksRunning
        } else if signals.reviewDecision == "REVIEW_REQUIRED"
                    || (signals.pendingReviewRequests > 0 && signals.reviewDecision != "APPROVED") {
            self = .awaitingReview
        } else if signals.mergeable == "MERGEABLE" && (signals.checks == nil || signals.checks == "SUCCESS") {
            self = .readyToMerge
        } else {
            self = .open
        }
    }

    /// A ready reading held against GitHub's own merge verdict, which also knows
    /// the rules the cheap signals can't see — a ruleset, a required check that
    /// hasn't reported yet. Ready is the one claim someone acts on unchecked, so a
    /// verdict short of mergeable takes it back to plain open.
    func confirmed(byMergeState mergeState: String?) -> PullRequestStatus {
        guard self == .readyToMerge else { return self }
        return ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(mergeState) ? self : .open
    }

    /// Lower needs you sooner: merge what's ready, fix what's broken, answer the
    /// bots, then the ones that are only waiting on someone else.
    var actionRank: Int {
        switch self {
        case .readyToMerge: 0
        case .conflicts, .checksFailing, .changesRequested: 1
        case .botFeedback: 2
        case .checksRunning: 3
        case .awaitingReview: 4
        case .open: 5
        }
    }

    var label: String {
        switch self {
        case .readyToMerge: localized("Ready to Merge")
        case .conflicts: localized("Conflicts")
        case .checksFailing: localized("Checks Failing")
        case .changesRequested: localized("Changes Requested")
        case .botFeedback(let reviewer, let comments): comments > 0 ? "\(reviewer) · \(comments)" : reviewer
        case .checksRunning: localized("Checks Running")
        case .awaitingReview: localized("Awaiting Review")
        case .open: localized("issue.state.open")
        }
    }

    /// The same hues the Linear pane's pull request chips use for the states both
    /// read, so a color means one thing across the app. Bot feedback is orange: it
    /// wants a fix, but a softer one than red's broken build.
    var tint: Color {
        switch self {
        case .readyToMerge, .open: .green
        case .conflicts, .checksFailing, .changesRequested: .red
        case .botFeedback: .orange
        case .checksRunning: .yellow
        case .awaitingReview: .blue
        }
    }
}

/// A tracker label, with the server-assigned color carried as a hex string.
struct IssueLabel: Hashable, Sendable {
    let name: String
    /// Six-digit hex without `#`, as GitHub's API returns it.
    let colorHex: String

    var color: Color {
        var value: UInt64 = 0
        guard Scanner(string: colorHex).scanHexInt64(&value), colorHex.count == 6 else {
            return .secondary
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The remote container a project is bound to — a GitHub `owner/repo` (a
/// Linear team later). `id` is the provider-native identifier.
struct IssueContainer: Hashable, Sendable {
    let provider: IssueProviderID
    let id: String
}

/// A repository the Issues pane could bind this project to. Usually there is
/// exactly one and the pane never mentions it; a fork checkout has several, and
/// then the user picks (#427).
struct IssueRepositoryCandidate: Hashable, Identifiable, Sendable {
    /// `owner/repo` — unique across the list, so it doubles as the identity.
    let slug: String
    /// The git remote this came from, or `nil` for a repository the pane knows
    /// about without the checkout naming it: the fork parent GitHub reported, or
    /// a slug the user picked before the remote went away.
    let remoteName: String?

    var id: String { slug }
}

/// The list request: which kind, and the light filters the top bar offers.
/// Selected labels combine as AND, GitHub's own filter semantics.
struct IssueQuery: Hashable, Sendable {
    var kind: IssueKind = .issue
    var openOnly = true
    var labels: Set<String> = []
    /// Pull requests only: list the open ones waiting on your review above the rest,
    /// whatever Mine and Open Only say.
    var toReview = true
    /// Kept per kind so each tab has its own default: the pull requests that need
    /// you are the ones you care about, while an issue tracker is read as a whole.
    private var issuesAssignedToMe = false
    private var pullRequestsMine = true

    var assignedToMe: Bool {
        get { kind == .pullRequest ? pullRequestsMine : issuesAssignedToMe }
        set {
            if kind == .pullRequest { pullRequestsMine = newValue } else { issuesAssignedToMe = newValue }
        }
    }

    /// Whether the active kind's switches differ from where a fresh pane starts them.
    var isNarrowedFromDefault: Bool {
        let fresh = IssueQuery(kind: kind)
        return openOnly != fresh.openOnly || assignedToMe != fresh.assignedToMe || !labels.isEmpty
            || (kind == .pullRequest && toReview != fresh.toReview)
    }
}

/// One row of the list. `identifier` is the provider-native short handle —
/// GitHub's `#95`, Linear's `TER-123`.
struct IssueSummary: Identifiable, Hashable, Sendable {
    let number: Int
    let identifier: String
    let title: String
    let kind: IssueKind
    let state: IssueItemState
    let labels: [IssueLabel]
    let author: String
    let updatedAt: Date
    let url: URL?
    /// A pull request with your review still pending, asked of you or of a team
    /// you're on. The list shows these in their own section above the rest.
    var awaitsYourReview = false
    /// Open pull requests only, and only once GitHub's merge signals came back.
    var pullRequestStatus: PullRequestStatus?

    var id: Int { number }

    var tint: Color { pullRequestStatus?.tint ?? state.tint(for: kind) }

    /// Where this sits in a list ordered by what needs doing: open pull requests by
    /// their status, then drafts, then the finished ones.
    var actionRank: Int {
        switch state {
        case .open: pullRequestStatus?.actionRank ?? PullRequestStatus.open.actionRank
        case .draft: 6
        case .merged: 7
        case .closed: 8
        }
    }

    /// The pull request list's order: the ones awaiting your review keep the lead
    /// they're given, the rest follow by `actionRank`. `sorted` isn't stable, so the
    /// incoming order — the listing's newest first — breaks ties explicitly.
    static func orderedByAction(_ items: [IssueSummary]) -> [IssueSummary] {
        let rest = items.filter { !$0.awaitsYourReview }.enumerated()
            .sorted { ($0.element.actionRank, $0.offset) < ($1.element.actionRank, $1.offset) }
            .map(\.element)
        return items.filter(\.awaitsYourReview) + rest
    }

    /// Whether the list's search field keeps this row: every whitespace-separated
    /// term must land in the title or the identifier. Matching the identifier
    /// rather than the bare number lets `#12` and `12` both find `#123`.
    /// `localizedStandardContains` is Finder's own search comparison — case- and
    /// diacritic-insensitive.
    func matches(search: String) -> Bool {
        search.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            title.localizedStandardContains(term) || identifier.localizedStandardContains(term)
        }
    }
}

/// One comment in the detail thread.
struct IssueComment: Identifiable, Equatable, Sendable {
    let id: Int
    let author: String
    let avatarURL: URL?
    let createdAt: Date
    let bodyMarkdown: String
}

/// The full item: the summary plus its markdown body and comment thread.
struct IssueDetail: Equatable, Sendable {
    let summary: IssueSummary
    let bodyMarkdown: String
    let authorAvatarURL: URL?
    let createdAt: Date
    let comments: [IssueComment]
}

/// One PR file with its unified-diff `patch` straight from the GitHub API — the Files
/// tab renders from this without a local checkout or extra fetch. `patch` is `nil` when
/// GitHub omits it (a binary file, or a diff too large to inline).
struct PullRequestFile: Sendable {
    let change: GitChange
    let patch: String?
    /// GitHub's `contents_url` for this file, already pinned to the PR head. The patch
    /// carries three lines of context, so expanding a hunk boundary means reading the file
    /// itself — this is where from, without fetching the PR's refs.
    let contentsURL: URL?
}

// MARK: - Provider protocol

/// The read surface every tracker backend implements. Write operations
/// (reactions, labels, comments — issue #100) extend this protocol when they
/// land; keeping M1's surface read-only keeps the first conformance honest.
protocol IssueProvider: Sendable {
    var id: IssueProviderID { get }
    var capabilities: IssueCapabilities { get }

    func issues(in container: IssueContainer, query: IssueQuery) async throws -> [IssueSummary]
    func detail(_ number: Int, in container: IssueContainer) async throws -> IssueDetail
}
