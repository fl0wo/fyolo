import XCTest
@testable import fyolo

/// The Linear pane's pure logic: which pull request titles name which ticket,
/// what color a pull request's chip takes, and the order tickets are listed in.
final class LinearPluginTests: XCTestCase {
    private func pattern(_ keys: [String] = ["ENG", "OPS"]) throws -> LinearTicketPattern {
        try XCTUnwrap(LinearTicketPattern(teamKeys: keys))
    }

    // MARK: Title matching

    func testFindsIdentifiersWhereverTheTitleWritesThem() throws {
        let pattern = try pattern()
        XCTAssertEqual(pattern.identifiers(in: "ENG-123 Fix login"), ["ENG-123"])
        XCTAssertEqual(pattern.identifiers(in: "[ENG-123] Fix login"), ["ENG-123"])
        XCTAssertEqual(pattern.identifiers(in: "feat(auth): fix login (ENG-123)"), ["ENG-123"])
        XCTAssertEqual(pattern.identifiers(in: "Fix login ENG-123:"), ["ENG-123"])
    }

    func testNormalizesCaseAndLeadingZeros() throws {
        XCTAssertEqual(try pattern().identifiers(in: "eng-012 fix"), ["ENG-12"])
    }

    func testAPullRequestCanNameSeveralTickets() throws {
        XCTAssertEqual(
            try pattern().identifiers(in: "ENG-1, OPS-22 and ENG-1 again"),
            ["ENG-1", "OPS-22"])
    }

    func testIgnoresLookAlikesAndUnknownTeams() throws {
        let pattern = try pattern()
        XCTAssertEqual(pattern.identifiers(in: "Decode UTF-8 and ISO-8601 dates"), [])
        XCTAssertEqual(pattern.identifiers(in: "WEB-12 belongs to another workspace"), [])
        XCTAssertEqual(pattern.identifiers(in: "XENG-12 and ENG-12345678901"), [])
        XCTAssertEqual(pattern.identifiers(in: "ENG-"), [])
    }

    func testPrefersTheLongerKeyWhenKeysShareAPrefix() throws {
        let pattern = try pattern(["ENG", "ENGX"])
        XCTAssertEqual(pattern.identifiers(in: "ENGX-4 and ENG-5"), ["ENGX-4", "ENG-5"])
    }

    func testNoTeamsMeansNoPattern() {
        XCTAssertNil(LinearTicketPattern(teamKeys: []))
    }

    func testIndexListsEachPullRequestUnderEveryTicketItNames() throws {
        func pullRequest(_ number: Int, _ title: String) throws -> LinkedPullRequest {
            LinkedPullRequest(
                number: number, title: title,
                url: try XCTUnwrap(URL(string: "https://github.com/acme/app/pull/\(number)")),
                repository: "acme/app", status: .open)
        }
        let index = try pattern().index([
            pullRequest(1, "ENG-1 first"),
            pullRequest(2, "ENG-1 and OPS-2"),
            pullRequest(3, "Unrelated"),
        ])
        XCTAssertEqual(index["ENG-1"]?.map(\.number), [1, 2])
        XCTAssertEqual(index["OPS-2"]?.map(\.number), [2])
        XCTAssertEqual(index.count, 2)
    }

    // MARK: Searching

    func testSearchesBatchSixIdentifiersEachInsideTheOwnersScope() {
        let identifiers = (1...13).map { "ENG-\($0)" }
        let queries = GitHubPullRequestLookup.searchQueries(for: identifiers, owner: "acme")
        // GitHub answers a seventh OR'd term with nothing, so no query may hold one.
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(
            queries[0],
            #"is:pr user:acme in:title "ENG-1" OR "ENG-2" OR "ENG-3" OR "ENG-4" OR "ENG-5" OR "ENG-6""#)
        XCTAssertEqual(queries[2], #"is:pr user:acme in:title "ENG-13""#)
        XCTAssertTrue(queries.allSatisfy { $0.components(separatedBy: " OR ").count <= 6 })
    }

    func testNoIdentifiersMeansNoSearch() {
        XCTAssertEqual(GitHubPullRequestLookup.searchQueries(for: [], owner: "acme"), [])
    }

    func testSearchResultsFileUnderOnlyTheTicketsAskedAbout() throws {
        func pullRequest(_ number: Int, _ title: String) throws -> LinkedPullRequest {
            LinkedPullRequest(
                number: number, title: title,
                url: try XCTUnwrap(URL(string: "https://github.com/acme/app/pull/\(number)")),
                repository: "acme/app", status: .open)
        }
        // Search is fuzzy: #2 came back for ENG-1 but names ENG-12, and #3 names a
        // ticket that wasn't asked about.
        let found = try [
            pullRequest(1, "ENG-1 fix"),
            pullRequest(2, "ENG-12 unrelated"),
            pullRequest(3, "OPS-4 and ENG-1"),
        ]
        let filed = try pattern().index(found, for: ["ENG-1", "ENG-2"])
        XCTAssertEqual(filed["ENG-1"]?.map(\.number), [1, 3])
        // Asked about and found nothing: recorded, so it isn't searched again.
        XCTAssertEqual(filed["ENG-2"]?.count, 0)
        XCTAssertNil(filed["ENG-12"])
        XCTAssertNil(filed["OPS-4"])
    }

    // MARK: Status

    private func status(
        _ state: String = "OPEN", draft: Bool = false, checks: String? = nil,
        review: String? = nil, merge: String? = nil
    ) -> LinkedPullRequestStatus {
        LinkedPullRequestStatus(state: state, isDraft: draft, checks: checks, reviewDecision: review, mergeState: merge)
    }

    func testOutcomesWinOverEverythingElse() {
        XCTAssertEqual(status("MERGED", checks: "FAILURE", review: "APPROVED"), .merged)
        XCTAssertEqual(status("CLOSED", draft: true), .closed)
    }

    func testDraftThenChecksThenReview() {
        XCTAssertEqual(status(draft: true, checks: "FAILURE"), .draft)
        XCTAssertEqual(status(checks: "ERROR", review: "APPROVED", merge: "CLEAN"), .failing)
        XCTAssertEqual(status(checks: "PENDING", review: "REVIEW_REQUIRED"), .pending)
        XCTAssertEqual(status(checks: "SUCCESS", review: "CHANGES_REQUESTED"), .inReview)
        XCTAssertEqual(status(checks: "SUCCESS", review: "REVIEW_REQUIRED", merge: "BLOCKED"), .inReview)
    }

    func testReadyOnlyWhenGitHubSaysTheMergeIsClean() {
        XCTAssertEqual(status(checks: "SUCCESS", review: "APPROVED", merge: "CLEAN"), .readyToMerge)
        XCTAssertEqual(status(checks: "SUCCESS", review: "APPROVED", merge: "BEHIND"), .open)
        XCTAssertEqual(status(), .open)
    }

    // MARK: Ordering

    private func issue(
        _ identifier: String, priority: Double, state: String = "unstarted",
        assignee: String? = nil, updated: TimeInterval = 0
    ) throws -> LinearIssue {
        LinearIssue(
            id: identifier, identifier: identifier, title: identifier, priority: priority,
            url: try XCTUnwrap(URL(string: "https://linear.app/acme/issue/\(identifier)")),
            updatedAt: Date(timeIntervalSince1970: updated),
            state: LinearWorkflowState(name: state, type: state, color: "#888888"),
            assignee: assignee.map { LinearUser(id: $0, displayName: $0, avatarUrl: nil) },
            labels: LinearNodes(nodes: []))
    }

    func testViewerFirstThenPriorityWithNoPriorityLast() throws {
        let issues = [
            try issue("ENG-1", priority: 0, assignee: "me"),
            try issue("ENG-2", priority: 4, assignee: "me"),
            try issue("ENG-3", priority: 1, assignee: "someone"),
            try issue("ENG-4", priority: 2),
            try issue("ENG-5", priority: 1, assignee: "me"),
        ]
        let split = LinearIssueOrdering.split(issues, viewerID: "me")
        XCTAssertEqual(split.mine.map(\.identifier), ["ENG-5", "ENG-2", "ENG-1"])
        XCTAssertEqual(split.others.map(\.identifier), ["ENG-3", "ENG-4"])
    }

    func testWithinAPriorityStartedWorkThenMostRecentlyUpdated() throws {
        let issues = [
            try issue("ENG-1", priority: 3, state: "backlog", updated: 300),
            try issue("ENG-2", priority: 3, state: "unstarted", updated: 100),
            try issue("ENG-3", priority: 3, state: "started", updated: 50),
            try issue("ENG-4", priority: 3, state: "unstarted", updated: 200),
        ]
        let split = LinearIssueOrdering.split(issues, viewerID: nil)
        XCTAssertEqual(split.others.map(\.identifier), ["ENG-3", "ENG-4", "ENG-2", "ENG-1"])
    }

    // MARK: Decoding

    func testDecodesLinearTimestampsWithMilliseconds() throws {
        let json = Data("""
        {"id":"a","identifier":"ENG-1","title":"t","priority":2,"url":"https://linear.app/x/issue/ENG-1",
         "updatedAt":"2026-10-14T09:30:12.345Z","state":{"name":"Todo","type":"unstarted","color":"#e2e2e2"},
         "assignee":null,"labels":{"nodes":[{"name":"Bug","color":"#eb5757"}]}}
        """.utf8)
        let decoded = try LinearClient.decoder.decode(LinearIssue.self, from: json)
        XCTAssertEqual(decoded.identifier, "ENG-1")
        XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970, 1_791_970_212.345, accuracy: 0.01)
        XCTAssertEqual(decoded.labels.nodes.first?.name, "Bug")
    }

    func testLinkedTicketsReadFromThisTicketsSide() throws {
        let json = Data("""
        {"id":"a","identifier":"ENG-1","title":"t","description":null,"priority":0,
         "url":"https://linear.app/x/issue/ENG-1","createdAt":"2026-10-14T09:30:12.000Z",
         "state":{"name":"Todo","type":"unstarted","color":"#e2e2e2"},"assignee":null,"creator":null,
         "team":{"id":"t","key":"ENG","name":"Engineering"},"labels":{"nodes":[]},"parent":null,
         "children":{"nodes":[]},
         "relations":{"nodes":[{"type":"blocks","relatedIssue":{"id":"b","identifier":"ENG-2","title":"b",
           "state":{"name":"Todo","type":"unstarted","color":"#e2e2e2"}}}]},
         "inverseRelations":{"nodes":[{"type":"blocks","issue":{"id":"c","identifier":"ENG-3","title":"c",
           "state":{"name":"Todo","type":"unstarted","color":"#e2e2e2"}}}]},
         "comments":{"nodes":[]}}
        """.utf8)
        let detail = try LinearClient.decoder.decode(LinearIssueDetail.self, from: json)
        let groups = detail.linkedTickets.map { ($0.title, $0.tickets.map(\.identifier)) }
        XCTAssertEqual(groups.map(\.0), ["Blocks", "Blocked By"])
        XCTAssertEqual(groups.map(\.1), [["ENG-2"], ["ENG-3"]])
    }
}
