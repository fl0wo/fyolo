import FyoloShared
import XCTest
@testable import fyolo

/// Pins the live-title sanitizer both platforms display through: what counts as
/// the animated status mark agents prefix their `OSC 0/2` title with, and what
/// is the title itself.
final class LiveTerminalTitleTests: XCTestCase {
    func testSpinnerFramesCollapseToOneTitle() {
        let frames = ["✳ Refactoring", "✻ Refactoring", "· Refactoring", "⁝ Refactoring"]
        XCTAssertEqual(Set(frames.map(LiveTerminalTitle.sanitized)), ["Refactoring"])
    }

    func testStripsLeadingRunAndWhitespace() {
        XCTAssertEqual(
            LiveTerminalTitle.sanitized("  ✳ ·· Building the app  "), "Building the app")
    }

    /// Only the *leading* run goes: separators inside the title carry meaning
    /// (Pi reports `pi | 019fe98c | working`).
    func testKeepsInteriorPunctuation() {
        XCTAssertEqual(
            LiveTerminalTitle.sanitized("· pi | 019fe98c | working"), "pi | 019fe98c | working")
    }

    /// Callers treat empty as "nothing to show" rather than blanking a good title.
    func testMarkOnlyTitleSanitizesToEmpty() {
        XCTAssertEqual(LiveTerminalTitle.sanitized(" ✳ "), "")
    }

    func testPlainTitleIsUnchanged() {
        XCTAssertEqual(LiveTerminalTitle.sanitized("fyolo — zsh"), "fyolo — zsh")
    }

    func testPromptTitleCollapsesFormattingAndWhitespace() {
        XCTAssertEqual(
            AgentPromptTitle.normalized("  ##  Refactor\n the   Codex\t integration  "),
            "Refactor the Codex integration")
    }

    func testPromptTitleIsBoundedAtAWordBoundary() {
        let title = AgentPromptTitle.normalized(
            "Refactor the Codex hook so Fyolo can show a useful automatic title in every sidebar session")

        XCTAssertNotNil(title)
        XCTAssertLessThanOrEqual(title?.count ?? .max, AgentPromptTitle.maximumLength)
        XCTAssertEqual(
            title, "Refactor the Codex hook so Fyolo can show a useful automatic…")
    }

    func testPromptTitleRejectsFormattingOnlyInput() {
        XCTAssertNil(AgentPromptTitle.normalized("  ## -- `  "))
    }

    func testAgentTitlePrecedence() {
        XCTAssertEqual(
            AgentSessionTitle.automatic(
                native: "Native title", promptFallback: "Prompt title",
                placeholder: "Codex"),
            "Native title")
        XCTAssertEqual(
            AgentSessionTitle.automatic(
                native: nil, promptFallback: "Prompt title", placeholder: "Codex"),
            "Prompt title")
        XCTAssertEqual(
            AgentSessionTitle.automatic(
                native: nil, promptFallback: nil, placeholder: "Codex"),
            "Codex")
    }

    /// The remote regression: a label Fyolo composed for a row on another machine
    /// is a placeholder, so the agent's live title still speaks through it. Reading
    /// it as a chosen name is what froze a VPS row at `boxlit · ukvps` while its
    /// local twin followed the conversation.
    func testComposedRemoteLabelStillYieldsToTheLiveTitle() {
        XCTAssertEqual(
            AgentSessionTitle.automatic(
                native: "Wire up the relay", promptFallback: nil,
                placeholder: "boxlit · ukvps"),
            "Wire up the relay")
    }

    /// The invariant the field shape buys: rewriting the placeholder — a promotion,
    /// a demotion, a state-file migration renumbering old rows — can never disturb
    /// the name someone gave. A flag beside `title` had to be updated at every one
    /// of those sites, and the ones that forgot pinned the row to a name nobody gave.
    func testRewritingThePlaceholderLeavesAGivenNameAlone() {
        var session = Session(title: "Terminal 3", agent: .terminal)
        session.givenTitle = "Deploy watch"

        session.title = "Claude Code"

        XCTAssertEqual(session.givenTitle, "Deploy watch")
    }

    func testCodexHookForwardsToolAndPromptFields() {
        let hooks = AgentDefinition.codex.hookSpec
        XCTAssertEqual(hooks?.tool, "tool_name")
        XCTAssertEqual(hooks?.promptTitle, "prompt")
    }

    func testPromptTitlePersistsWithSession() throws {
        var session = Session(title: "Codex", agent: .codex)
        session.promptTitle = "Refactor Codex titles"

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        XCTAssertEqual(decoded.promptTitle, "Refactor Codex titles")
    }

    func testGivenTitlePersistsWithSession() throws {
        var session = Session(title: "Codex", agent: .codex)
        session.givenTitle = "Deploy watch"

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        XCTAssertEqual(decoded.givenTitle, "Deploy watch")
    }

    /// A state file written before `givenTitle` existed has to be read back into the
    /// same meaning: Fyolo's own conventions are placeholders, a real name is kept —
    /// and the `<project> · <host>` label the old remote path wrote is recovered as
    /// the placeholder it always was, so an already-frozen row unfreezes on upgrade.
    func testGivenTitleIsRecoveredFromStateFilesWithoutIt() {
        XCTAssertNil(
            Session.recoveredGivenTitle("Terminal 3", agent: .terminal, remoteHost: nil))
        XCTAssertNil(
            Session.recoveredGivenTitle("Claude Code", agent: .claudeCode, remoteHost: nil))
        XCTAssertNil(
            Session.recoveredGivenTitle("boxlit · ukvps", agent: .claudeCode, remoteHost: "ukvps"))
        XCTAssertNil(
            Session.recoveredGivenTitle("ukvps", agent: .terminal, remoteHost: "ukvps"))
        XCTAssertEqual(
            Session.recoveredGivenTitle("Deploy watch", agent: .claudeCode, remoteHost: "ukvps"),
            "Deploy watch")
        // The same composed shape on a *local* session was never written by Fyolo,
        // so it can only be a name someone typed.
        XCTAssertEqual(
            Session.recoveredGivenTitle("boxlit · ukvps", agent: .terminal, remoteHost: nil),
            "boxlit · ukvps")
    }
}
