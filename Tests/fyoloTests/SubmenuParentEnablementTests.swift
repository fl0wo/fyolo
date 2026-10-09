import AppKit
import XCTest

/// The AppKit rule that dimmed ＋ ▸ New Workspace (and ＋ ▸ Open Project, back
/// when it grew a device submenu too).
///
/// The row is built as an ordinary action item with an explicit `target`, then
/// reshaped into a submenu parent once a second machine exists
/// (`refreshNewWorkspaceItem`). Nulling the action is
/// not enough: assigning `submenu` makes AppKit install its own `submenuAction:`,
/// and it only adopts the submenu as the item's target when the target is already
/// nil. A leftover target keeps the selector pointed at the AppDelegate, which
/// cannot perform it, so the row dims — while still drawing its arrow, which is
/// what made the symptom read as a broken submenu rather than a wrong target.
///
/// Two things are pinned separately, because `NSMenu.update()` on a detached menu
/// reports them differently. A stripped action does dim the item here, so that one
/// is asserted directly. A wrong *target* does not — the live app is where that
/// showed, with the reshaped row logging `action=submenuAction: target=set` and
/// drawing grey — so the target case is pinned as wiring rather than as state.
final class SubmenuParentEnablementTests: XCTestCase {
    /// Stands in for the AppDelegate: a plausible menu target that, like it, does
    /// not implement `submenuAction:`.
    private final class Target: NSObject {
        @objc func openProject(_ sender: Any?) {}
    }

    private static let submenuAction = Selector(("submenuAction:"))

    /// `NSMenuItem.target` is weak, so the stand-in delegate is held by the test
    /// for as long as the item is — the app holds its AppDelegate the same way.
    private let delegate = Target()

    private func reshaped(clearingTarget: Bool) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Open Project", action: #selector(Target.openProject(_:)), keyEquivalent: "")
        item.target = delegate
        // Exactly the reshape the delegate performs.
        item.action = nil
        if clearingTarget { item.target = nil }
        item.submenu = NSMenu(title: "Open Project")
        return item
    }

    /// The trap: AppKit owns a submenu parent's action, so nulling it is not what
    /// decides anything — the target is.
    func testAttachingASubmenuInstallsAppKitsOwnAction() {
        let item = reshaped(clearingTarget: true)
        XCTAssertEqual(item.action.map(NSStringFromSelector), NSStringFromSelector(Self.submenuAction))
    }

    /// The bug: AppKit does not replace a target that is already set, so
    /// `submenuAction:` stays aimed at the AppDelegate, which never implements it.
    func testALeftoverTargetKeepsTheRowAimedAtTheDelegate() {
        XCTAssertTrue(
            reshaped(clearingTarget: false).target is Target,
            "the delegate is still what AppKit will ask to open the submenu")
    }

    /// The fix: cleared before the submenu is attached, AppKit takes ownership of
    /// the target — which is what `makeNewChatItem` gets for free by never setting
    /// one.
    func testClearingTheTargetLetsAppKitOwnIt() {
        XCTAssertTrue(
            reshaped(clearingTarget: true).target is NSMenu,
            "AppKit adopts the menu itself once nothing else claims the item")
    }

    /// This menu is refreshed on every open, so the reshape runs again on an item
    /// that is already a submenu parent. What the delegate used to do then — clear
    /// the action unconditionally — is what dimmed the row for the rest of the
    /// launch: it worked once, then never again.
    ///
    /// Spelled out as two shapes rather than by calling the delegate:
    /// `refreshNewWorkspaceItem` is private to the AppDelegate and needs a store and
    /// a window, so what is pinned here is the AppKit rule that makes its guard
    /// necessary, not the guard itself.
    func testClearingTheActionOnASecondRefreshDimsTheRow() {
        let menu = NSMenu(title: "New Session")
        let item = reshaped(clearingTarget: true)
        menu.addItem(item)
        menu.update()
        XCTAssertTrue(item.isEnabled, "the first pull-down was always fine")

        // The old second pass, verbatim.
        item.action = nil
        item.target = nil
        menu.update()
        XCTAssertFalse(
            item.isEnabled,
            "stripping AppKit's submenuAction: leaves a submenu parent with no action")
    }

    /// The fixed second pass: the refresh returns before touching either, and the
    /// row survives every subsequent open.
    func testLeavingAppKitsActionAloneKeepsTheRowLive() {
        let menu = NSMenu(title: "New Session")
        let item = reshaped(clearingTarget: true)
        menu.addItem(item)
        menu.update()
        menu.update()
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(
            item.action.map(NSStringFromSelector), NSStringFromSelector(Self.submenuAction),
            "AppKit's action survives a refresh that leaves it alone")
    }
}
