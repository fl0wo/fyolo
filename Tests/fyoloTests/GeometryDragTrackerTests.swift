import XCTest
@testable import fyolo

/// The gate that decides whether a viewport declaration streams or debounces.
///
/// Worth pinning because both of its failure modes are silent. A drag that
/// never reports leaves the session reflowing only after the user lets go —
/// the bug this tracker was widened to fix, which shipped unnoticed for as
/// long as a window edge was the only drag AppKit announced. An end that never
/// arrives is worse and quieter: `isActive` stays true forever, every later
/// declaration takes the streaming cadence, and the 400ms debounce stops
/// protecting the app's own layout animations from declaring a size nobody
/// chose. Neither shows up as a crash or a failed build.
final class GeometryDragTrackerTests: XCTestCase {
    private let tracker = GeometryDragTracker.shared

    override func tearDown() {
        // The tracker is a singleton and these tests mutate it, so a failure
        // mid-test must not leak a drag into the next one.
        while tracker.isActive { tracker.endDrag() }
        super.tearDown()
    }

    func testNoDragIsNotActive() {
        XCTAssertFalse(tracker.isActive)
    }

    func testAReportedDragIsActiveUntilItEnds() {
        tracker.beginDrag()
        XCTAssertTrue(tracker.isActive)
        tracker.endDrag()
        XCTAssertFalse(tracker.isActive)
    }

    /// The sidebar divider and a pane divider report independently, and AppKit
    /// can be mid window-resize besides. Whoever ends first must not clear the
    /// others.
    func testEveryReportedDragMustEndBeforeTheGateCloses() {
        tracker.beginDrag()
        tracker.beginDrag()
        tracker.endDrag()
        XCTAssertTrue(tracker.isActive)
        tracker.endDrag()
        XCTAssertFalse(tracker.isActive)
    }

    /// An unmatched end is the safety path, not a bug: a gesture torn down
    /// mid-drag ends itself from `onDisappear` and may race its own `onEnded`.
    /// It must floor at zero rather than go negative, or the next real drag
    /// would report itself and still read as idle.
    func testAnUnmatchedEndCannotGoNegative() {
        tracker.endDrag()
        tracker.endDrag()
        tracker.beginDrag()
        XCTAssertTrue(tracker.isActive)
        tracker.endDrag()
        XCTAssertFalse(tracker.isActive)
    }
}
