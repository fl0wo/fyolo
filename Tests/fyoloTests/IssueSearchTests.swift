import XCTest
@testable import fyolo

/// What the Issues pane's search field keeps in the list: a row stays when every
/// typed term lands in its title or its `#number`.
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
}
