import XCTest
@testable import fyolo

/// The binary a command line names, resolved the way `fyolod` resolves it.
///
/// These cases are pinned identically in `machine::first_word`'s own test. The
/// two implementations must agree: the app decides an agent is available and the
/// daemon decides whether to write its config, and when they disagree the app
/// reports a working agent while the machine quietly refuses it hooks.
final class AgentAvailabilityFirstWordTests: XCTestCase {

    private func word(_ command: String) -> String? {
        AgentAvailability.firstWord(command)
    }

    func testAQuotedPathKeepsItsSpaces() {
        // The case that most needs a path typed by hand: splitting on a bare
        // space answers "not installed" for a CLI sitting right there.
        XCTAssertEqual(word("\"/Agent Tools/codex\" --flag"), "/Agent Tools/codex")
        XCTAssertEqual(word("'/Agent Tools/codex'"), "/Agent Tools/codex")
        XCTAssertEqual(word("/Agent\\ Tools/codex x"), "/Agent Tools/codex")
    }

    func testArgumentsAndPaddingAreNotPartOfTheBinary() {
        XCTAssertEqual(word("  claude --dangerously"), "claude")
        XCTAssertNil(word("   "))
    }

    func testABackslashFollowsTheShellsThreeRules() {
        // Literal inside single quotes.
        XCTAssertEqual(word("'/opt/a\\tools/cli'"), "/opt/a\\tools/cli")
        // Inside double quotes, special only before $ ` " \\ and newline — so a
        // path keeps the backslash it really has.
        XCTAssertEqual(word("\"/opt/a\\tools/cli\""), "/opt/a\\tools/cli")
        XCTAssertEqual(word("\"/opt/a\\\"b/cli\""), "/opt/a\"b/cli")
        // An escape for anything, unquoted.
        XCTAssertEqual(word("/opt/a\\tools/cli"), "/opt/atools/cli")
    }

    func testALineContinuationDisappears() {
        // Backslash-newline is removed by the shell, quoted or not; keeping the
        // newline names a file that cannot exist.
        XCTAssertEqual(word("/usr/bin/tru\\\ne"), "/usr/bin/true")
        XCTAssertEqual(word("\"/usr/bin/tru\\\ne\""), "/usr/bin/true")
    }

    func testAnUnterminatedQuoteTakesTheRestOfTheLine() {
        XCTAssertEqual(word("'/opt/a b"), "/opt/a b")
    }

    func testACombiningMarkAfterTheClosingQuoteBelongsToTheWord() {
        // Swift's `Character` would fuse the quote and the mark into one
        // grapheme and never see the quote close. Scalars are why this passes,
        // and why it matches the daemon.
        XCTAssertEqual(word("'/tmp/cafe'\u{301} --flag"), "/tmp/cafe\u{301}")
    }
}
