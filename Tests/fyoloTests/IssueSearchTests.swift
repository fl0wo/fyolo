import XCTest
@testable import fyolo

/// What the Issues pane's search field keeps in the list: a row stays when every
/// typed term lands in its title or its `#number`; and which pull requests the
/// filter popover keeps.
final class IssueSearchTests: XCTestCase {
    private func item(_ number: Int, _ title: String) -> IssueSummary {
        IssueSummary(
            number: number, identifier: "#\(number)", title: title, kind: .pullRequest,
            state: .open, labels: [], author: "someone", updatedAt: Date(), url: nil)
    }

    func testEmptyOrBlankSearchKeepsEverything() {
        XCTAssertTrue(item(7, "Fix login").matches(search: ""))
        XCTAssertTrue(item(7, "Fix login").matches(search: "   "))
    }

    func testTitleMatchIgnoresCaseAndDiacritics() {
        XCTAssertTrue(item(7, "Fix Login redirect").matches(search: "login"))
        XCTAssertTrue(item(7, "Résumé upload").matches(search: "resume"))
        XCTAssertFalse(item(7, "Fix login").matches(search: "logout"))
    }

    func testNumberMatchesWithOrWithoutHash() {
        XCTAssertTrue(item(1234, "Anything").matches(search: "1234"))
        XCTAssertTrue(item(1234, "Anything").matches(search: "#1234"))
        XCTAssertTrue(item(1234, "Anything").matches(search: "#12"))
        XCTAssertFalse(item(1234, "Anything").matches(search: "#99"))
    }

    func testEveryTermMustLandInTitleOrNumber() {
        XCTAssertTrue(item(42, "Fix login redirect").matches(search: "redirect login"))
        XCTAssertTrue(item(42, "Fix login redirect").matches(search: "#42 login"))
        XCTAssertFalse(item(42, "Fix login redirect").matches(search: "login signup"))
    }

    // MARK: Pull request filters

    private func pullRequest() throws -> RawPullRequestListing {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RawPullRequestListing.self, from: Data("""
            {"number":5,"title":"t","state":"closed","draft":false,"merged_at":"2026-10-14T09:00:00Z",
             "labels":[{"name":"bug","color":"d73a4a"},{"name":"ci","color":null}],
             "user":{"login":"Author"},"assignees":[{"login":"assignee"}],
             "requested_reviewers":[{"login":"reviewer"}],
             "updated_at":"2026-10-14T09:00:00Z","html_url":"https://github.com/acme/app/pull/5"}
            """.utf8))
    }

    func testAPullRequestIsMineWhenIOpenedItAmAssignedOrAmAskedToReview() throws {
        let listing = try pullRequest()
        // Pull requests are rarely assigned, so the author alone has to count.
        XCTAssertTrue(listing.matches(labels: [], viewer: "author"))
        XCTAssertTrue(listing.matches(labels: [], viewer: "assignee"))
        XCTAssertTrue(listing.matches(labels: [], viewer: "reviewer"))
        XCTAssertFalse(listing.matches(labels: [], viewer: "someone-else"))
        XCTAssertTrue(listing.matches(labels: [], viewer: nil))
    }

    func testPullRequestLabelsCombineAsAnd() throws {
        let listing = try pullRequest()
        XCTAssertTrue(listing.matches(labels: ["bug", "ci"], viewer: nil))
        XCTAssertFalse(listing.matches(labels: ["bug", "docs"], viewer: nil))
    }

    func testAClosedPullRequestWithAMergeDateReadsAsMerged() throws {
        let summary = try pullRequest().summary()
        XCTAssertEqual(summary.state, .merged)
        XCTAssertEqual(summary.kind, .pullRequest)
        XCTAssertEqual(summary.author, "Author")
    }
}
