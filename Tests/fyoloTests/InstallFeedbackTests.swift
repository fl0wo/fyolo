import FyoloShared
import XCTest
@testable import fyolo

/// The line a Settings install button shows after it runs. The rule that matters:
/// anything that didn't land has to be visible and has to stay visible, so a
/// half-installed set of hooks can never read as a clean success.
final class InstallFeedbackTests: XCTestCase {
    private func outcome(succeeded: [String] = [], failed: [String] = []) -> InstallOutcome {
        var outcome = InstallOutcome()
        for name in succeeded { outcome.record(name, installed: true) }
        for name in failed { outcome.record(name, installed: false) }
        return outcome
    }

    func testNamesEveryTargetItReached() {
        let feedback = InstallFeedback.summarizing(
            outcome(succeeded: ["Claude Code", "Codex", "Cursor"]),
            headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.kind, .success)
        XCTAssertEqual(feedback.message, "Hooks reinstalled — Claude Code, Codex and Cursor.")
    }

    /// Past three the names would wrap the row, so the line counts instead.
    func testCountsBeyondThreeTargets() {
        let feedback = InstallFeedback.summarizing(
            outcome(succeeded: ["A", "B", "C", "D"]),
            headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.message, "Hooks reinstalled — 4 agents.")
    }

    /// A partial install is a failure: it stays on screen, because the half that
    /// didn't land is the half the user has to deal with.
    func testPartialInstallReportsAsFailure() {
        let feedback = InstallFeedback.summarizing(
            outcome(succeeded: ["Claude Code"], failed: ["Codex"]),
            headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.kind, .failure)
        XCTAssertEqual(
            feedback.message, "Hooks reinstalled — Claude Code. Couldn’t update Codex.")
    }

    func testTotalFailureNamesOnlyWhatFailed() {
        let feedback = InstallFeedback.summarizing(
            outcome(failed: ["~/.claude/CLAUDE.md"]),
            headline: "Note reinstalled", unit: "files")
        XCTAssertEqual(feedback.kind, .failure)
        XCTAssertEqual(feedback.message, "Couldn’t update ~/.claude/CLAUDE.md.")
    }

    /// Nothing attempted is not a success — silence is what this feedback exists
    /// to eliminate.
    func testEmptyOutcomeIsNotASuccess() {
        let feedback = InstallFeedback.summarizing(
            outcome(), headline: "Hooks reinstalled", unit: "agents")
        XCTAssertEqual(feedback.kind, .failure)
        XCTAssertEqual(feedback.message, "Nothing to install.")
    }

    /// Re-running the same action must restart the dismissal timer, which is keyed
    /// on the state's identity — so two identical messages must not compare equal.
    func testRepeatedShowChangesIdentity() {
        var state = InstallFeedbackState()
        state.show(.success("Installed."))
        let first = state
        state.show(.success("Installed."))
        XCTAssertNotEqual(first, state)
    }
}


/// Hooks and the skill are two rows of one reply, and they are reported as one
/// line per agent. What that line may not do is round a mixed result up: an
/// agent that took its hook and refused its skill is not installed.
final class InstallOutcomeFromReplyTests: XCTestCase {
    private func row(
        _ name: String, _ kind: String, _ status: String
    ) -> Fyolod.AgentInstallResult {
        Fyolod.AgentInstallResult(
            id: name.lowercased(), name: name, kind: kind,
            path: "/home/u/.\(name.lowercased())", status: status, detail: nil)
    }

    private func reply(
        _ results: [Fyolod.AgentInstallResult], present: [String] = []
    ) -> Fyolod.AgentsInstalledPayload {
        Fyolod.AgentsInstalledPayload(results: results, present: present)
    }

    /// Coverage is the machine's own answer, not something read off the rows.
    /// The rows undercount for reasons that say nothing about an agent being
    /// there — three catalog agents ship no hook spec, two share a skills
    /// directory — so the two must not be confused for each other.
    func testCoverageComesFromTheReplyNotTheRows() {
        let outcome = InstallOutcome(reply(
            [row("Claude Code", "hooks", "installed")],
            present: ["crush", "claudeCode"]))
        XCTAssertEqual(outcome.coveredIDs, ["claudeCode", "crush"])
        XCTAssertEqual(outcome.succeeded, ["Claude Code"])
    }

    /// A daemon too old to report it says nothing, which means *unknown*.
    func testAnOlderDaemonReportsNoCoverage() {
        XCTAssertNil(InstallOutcome(reply([row("Codex", "hooks", "installed")])).coveredIDs)
    }

    func testAnAgentThatTookBothIsNamedOnce() {
        let outcome = InstallOutcome(reply([
            row("Claude Code", "hooks", "installed"),
            row("Claude Code", "skill", "installed"),
            row("Codex", "hooks", "installed"),
        ]))
        XCTAssertEqual(outcome.succeeded, ["Claude Code", "Codex"])
        XCTAssertTrue(outcome.failed.isEmpty)
    }

    func testRefusingEitherHalfCountsAsRefused() {
        let outcome = InstallOutcome(reply([
            row("Claude Code", "hooks", "installed"),
            row("Claude Code", "skill", "failed"),
            row("Codex", "hooks", "installed"),
        ]))
        XCTAssertEqual(outcome.succeeded, ["Codex"])
        XCTAssertEqual(outcome.failed, ["Claude Code"])
    }

    /// A dialect the daemon does not write is neither a success to claim nor a
    /// failure to blame anyone for, so it stays out of the sentence entirely.
    func testASkippedDialectIsNotReportedEitherWay() {
        let outcome = InstallOutcome(reply([row("Kimi", "hooks", "skipped")]))
        XCTAssertTrue(outcome.isEmpty)
    }

    func testNothingToInstallStaysEmpty() {
        XCTAssertTrue(InstallOutcome(reply([])).isEmpty)
    }

    /// The install never reached the machine. A row that says so beats an empty
    /// success, which is what a swallowed error would look like.
    func testAnUnreachableMachineIsNamedAsAFailure() {
        let outcome = InstallOutcome(failure: "fyolod on vps is too old.")
        XCTAssertEqual(outcome.failed, ["fyolod on vps is too old."])
        XCTAssertTrue(outcome.succeeded.isEmpty)
    }
}
