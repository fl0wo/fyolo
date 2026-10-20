import XCTest
@testable import fyolo

/// What an open pull request is waiting on, read from GraphQL replies shaped like
/// GitHub's real ones (Copilot's review included), and the order the list puts
/// them in: ready first, then the ones to fix, then the ones only waiting.
final class PullRequestStatusTests: XCTestCase {
    private func status(_ json: String) throws -> PullRequestStatus {
        let raw = try JSONDecoder().decode(RawPullRequestSignals.self, from: Data(json.utf8))
        return PullRequestStatus(raw.signals)
    }

    private func reply(
        mergeable: String = "MERGEABLE", decision: String? = nil,
        checks: String? = "SUCCESS", requests: Int = 0, reviews: String = "", threads: String = ""
    ) -> String {
        let decisionJSON = decision.map { "\"\($0)\"" } ?? "null"
        let rollup = checks.map { "{\"state\": \"\($0)\"}" } ?? "null"
        return """
        {"number": 1, "mergeable": "\(mergeable)",
         "reviewDecision": \(decisionJSON), "reviewRequests": {"totalCount": \(requests)},
         "latestOpinionatedReviews": {"nodes": [\(reviews)]},
         "reviewThreads": {"nodes": [\(threads)]},
         "commits": {"nodes": [{"commit": {"statusCheckRollup": \(rollup)}}]}}
        """
    }

    private let copilotThread = """
    {"isResolved": false, "isOutdated": false, "comments": {"nodes": [{"author": {"__typename": "Bot", "login": "copilot-pull-request-reviewer"}}]}}
    """
    private let copilotReview = """
    {"state": "COMMENTED", "author": {"__typename": "Bot", "login": "copilot-pull-request-reviewer"}}
    """
    private let humanChanges = """
    {"state": "CHANGES_REQUESTED", "author": {"__typename": "User", "login": "alexdima"}}
    """

    func testCleanAndGreenIsReadyToMerge() throws {
        XCTAssertEqual(try status(reply(decision: "APPROVED")), .readyToMerge)
        XCTAssertEqual(try status(reply()), .readyToMerge)
    }

    func testBrokenOutranksTheReviewVerdict() throws {
        XCTAssertEqual(try status(reply(mergeable: "CONFLICTING", decision: "APPROVED")), .conflicts)
        XCTAssertEqual(try status(reply(decision: "APPROVED", checks: "FAILURE")), .checksFailing)
        XCTAssertEqual(
            try status(reply(decision: "CHANGES_REQUESTED", reviews: humanChanges)),
            .changesRequested)
    }

    func testCopilotCommentsAreBotFeedback() throws {
        let reviewed = reply(decision: "REVIEW_REQUIRED",
                             reviews: copilotReview, threads: [copilotThread, copilotThread].joined(separator: ","))
        XCTAssertEqual(try status(reviewed), .botFeedback(reviewer: "Copilot", comments: 2))
    }

    func testResolvedOrOutdatedBotThreadsAreAnswered() throws {
        let resolved = copilotThread.replacingOccurrences(of: "\"isResolved\": false", with: "\"isResolved\": true")
        let outdated = copilotThread.replacingOccurrences(of: "\"isOutdated\": false", with: "\"isOutdated\": true")
        XCTAssertEqual(try status(reply(threads: [resolved, outdated].joined(separator: ","))), .readyToMerge)
    }

    func testAPersonsChangeRequestOutranksABots() throws {
        let both = reply(decision: "CHANGES_REQUESTED",
                         reviews: [copilotReview, humanChanges].joined(separator: ","), threads: copilotThread)
        XCTAssertEqual(try status(both), .changesRequested)
    }

    func testABotRequestingChangesNamesTheApp() throws {
        let review = #"{"state": "CHANGES_REQUESTED", "author": {"__typename": "Bot", "login": "coderabbitai"}}"#
        XCTAssertEqual(try status(reply(reviews: review)),
                       .botFeedback(reviewer: "coderabbitai", comments: 0))
    }

    func testWaitingStates() throws {
        XCTAssertEqual(try status(reply(decision: "APPROVED", checks: "PENDING")), .checksRunning)
        XCTAssertEqual(try status(reply(decision: "REVIEW_REQUIRED")), .awaitingReview)
        // No review rule, but someone was asked: mergeable isn't ready until they answer.
        XCTAssertEqual(try status(reply(requests: 1)), .awaitingReview)
    }

    func testUncomputedMergeabilityClaimsNothing() throws {
        XCTAssertEqual(try status(reply(mergeable: "UNKNOWN", checks: nil)), .open)
    }

    func testReadyIsTakenBackWhenGitHubBlocksTheMerge() {
        XCTAssertEqual(PullRequestStatus.readyToMerge.confirmed(byMergeState: "CLEAN"), .readyToMerge)
        // microsoft/vscode#342131: approved, mergeable, green, and still BLOCKED by a rule.
        XCTAssertEqual(PullRequestStatus.readyToMerge.confirmed(byMergeState: "BLOCKED"), .open)
        XCTAssertEqual(PullRequestStatus.readyToMerge.confirmed(byMergeState: nil), .open)
        XCTAssertEqual(PullRequestStatus.checksFailing.confirmed(byMergeState: "BLOCKED"), .checksFailing)
    }

    // MARK: Order

    private func item(_ number: Int, _ state: IssueItemState, _ status: PullRequestStatus?,
                      awaitsYourReview: Bool = false) -> IssueSummary {
        var item = IssueSummary(
            number: number, identifier: "#\(number)", title: "", kind: .pullRequest,
            state: state, labels: [], author: "someone", updatedAt: Date(), url: nil)
        item.pullRequestStatus = status
        item.awaitsYourReview = awaitsYourReview
        return item
    }

    func testListLeadsWithWhatNeedsDoing() {
        let listing = [
            item(1, .open, .awaitingReview),
            item(2, .merged, nil),
            item(3, .open, .botFeedback(reviewer: "Copilot", comments: 1)),
            item(4, .draft, nil),
            item(5, .open, .checksFailing),
            item(6, .open, .readyToMerge),
            item(7, .open, .conflicts),
            item(8, .open, .checksRunning),
            item(9, .open, .readyToMerge, awaitsYourReview: true),
        ]
        XCTAssertEqual(IssueSummary.orderedByAction(listing).map(\.number), [9, 6, 5, 7, 3, 8, 1, 4, 2])
    }
}
