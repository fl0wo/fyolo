import XCTest
@testable import fyolo

/// ⌘W must never reach past what's in front of it, and must end exactly the
/// session in front of it — never the window while a session is still there, and
/// never a session while Settings holds the key window. Both properties live in
/// one decision (`CloseCommand.action`), and both regress silently — the window
/// still closes, just the wrong one — so they are pinned here. See
/// `docs/design/20260812-keyboard-command-design.md`.
final class CloseCommandTests: XCTestCase {
    // ⌘W passes whether a session is selected; ⌘⇧W always passes false.
    private func commandW(_ frontmost: CloseCommand.Frontmost, session: Bool) -> CloseCommand.Action {
        CloseCommand.action(for: frontmost, closingSession: session)
    }

    private func commandShiftW(_ frontmost: CloseCommand.Frontmost) -> CloseCommand.Action {
        CloseCommand.action(for: frontmost, closingSession: false)
    }

    func testCommandWClosesTheFocusedSessionBeforeTouchingTheWindow() {
        XCTAssertEqual(commandW(.mainWindow, session: true), .closeSession)
    }

    /// Chrome's last tab: with no session left to close, the key closes the window
    /// rather than going inert.
    func testCommandWClosesTheWindowOnlyWhenNoSessionIsLeft() {
        XCTAssertEqual(commandW(.mainWindow, session: false), .closeMainWindow)
    }

    /// The #242 regression guard: with Settings in front, ⌘W must close Settings
    /// rather than reach through and end a session in the terminal behind it.
    func testCommandWClosesAnAuxiliaryWindowInsteadOfTheTerminalBehindIt() {
        XCTAssertEqual(commandW(.auxiliaryWindow(closable: true), session: true), .closeKeyWindow)
        XCTAssertEqual(commandW(.auxiliaryWindow(closable: true), session: false), .closeKeyWindow)
    }

    /// The palette panel is borderless, so `performClose` would only beep at the
    /// user; it dismisses through the store flag that owns its presentation.
    func testCommandWDismissesThePaletteRatherThanBeepingAtIt() {
        XCTAssertEqual(commandW(.palette, session: true), .dismissPalette)
        XCTAssertEqual(commandShiftW(.palette), .dismissPalette)
    }

    func testAnUnclosableWindowSwallowsTheKeyInsteadOfBeeping() {
        XCTAssertEqual(commandW(.auxiliaryWindow(closable: false), session: false), .nothing)
    }

    /// The app outlives its window (#242). With nothing on screen there is nothing
    /// to close, and ending a session would act on a selection the user can't see.
    func testCloseKeysDoNothingWhenNoWindowIsOnScreen() {
        XCTAssertEqual(commandW(.nothing, session: true), .nothing)
        XCTAssertEqual(commandW(.nothing, session: false), .nothing)
        XCTAssertEqual(commandShiftW(.nothing), .nothing)
    }

    /// ⌘⇧W is "close the window" whatever is selected — it never ends a session.
    func testCommandShiftWNeverEndsASession() {
        XCTAssertEqual(commandShiftW(.mainWindow), .closeMainWindow)
    }

    /// Ungroup ships unbound but is rebindable, so it carries the same target
    /// check: a pane must never be peeled off behind an auxiliary window.
    func testUngroupOnlyActsWhenTheTerminalWindowIsInFront() {
        XCTAssertTrue(CloseCommand.actsOnTerminal(.mainWindow))
        XCTAssertFalse(CloseCommand.actsOnTerminal(.nothing))
        XCTAssertFalse(CloseCommand.actsOnTerminal(.palette))
        XCTAssertFalse(CloseCommand.actsOnTerminal(.auxiliaryWindow(closable: true)))
        XCTAssertFalse(CloseCommand.actsOnTerminal(.auxiliaryWindow(closable: false)))
    }

    /// The whole decision as a table, so any change to it has to be made on
    /// purpose. Only `.mainWindow` may read the selection; every other row is
    /// the same under both keys.
    func testEveryCombinationResolvesAsDocumented() {
        let expected: [(CloseCommand.Frontmost, Bool, CloseCommand.Action)] = [
            (.nothing, true, .nothing),
            (.nothing, false, .nothing),
            (.palette, true, .dismissPalette),
            (.palette, false, .dismissPalette),
            (.auxiliaryWindow(closable: true), true, .closeKeyWindow),
            (.auxiliaryWindow(closable: true), false, .closeKeyWindow),
            (.auxiliaryWindow(closable: false), true, .nothing),
            (.auxiliaryWindow(closable: false), false, .nothing),
            (.mainWindow, true, .closeSession),
            (.mainWindow, false, .closeMainWindow),
        ]
        for (frontmost, session, action) in expected {
            XCTAssertEqual(
                CloseCommand.action(for: frontmost, closingSession: session), action,
                "\(frontmost) closingSession=\(session)")
        }
    }
}
