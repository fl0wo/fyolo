import XCTest
@testable import fyolo

/// The arithmetic under both halves of reordering the agent roster.
///
/// It shipped without any. That mattered more than usual here: `onMove` is only
/// honoured by an editable `List`, so moving the roster into a grouped `Form`
/// stopped reordering *silently* — the rows still rendered, they just stopped
/// obeying a drag. The replacement is a drag plus Move Up / Move Down, and the
/// only reason the menu half exists is that it cannot break that quietly. Both
/// deserve to be held to what they claim.
final class AgentOrderingTests: XCTestCase {
    private let roster = ["claude", "codex", "droid", "cursor"]

    // MARK: Drag

    func testDraggingDownLandsOnTheTargetAndShiftsTheRestUp() {
        XCTAssertEqual(
            AgentOrdering.moving("claude", onto: "droid", in: roster),
            ["codex", "droid", "claude", "cursor"])
    }

    func testDraggingUpLandsOnTheTargetAndPushesItDown() {
        XCTAssertEqual(
            AgentOrdering.moving("cursor", onto: "codex", in: roster),
            ["claude", "cursor", "codex", "droid"])
    }

    /// Dropping a row on itself is the commonest accidental drag there is, and it
    /// must not be recorded as an edit — writing the order back would be a
    /// no-op that still churns the settings file.
    func testDroppingARowOnItselfChangesNothing() {
        XCTAssertNil(AgentOrdering.moving("codex", onto: "codex", in: roster))
    }

    /// A drag whose payload names an agent that has since left the list — removed
    /// from another window while the drag was in flight — is refused rather than
    /// resolved to some nearby index.
    func testADragFromOutsideTheListIsRefused() {
        XCTAssertNil(AgentOrdering.moving("ghost", onto: "codex", in: roster))
        XCTAssertNil(AgentOrdering.moving("codex", onto: "ghost", in: roster))
    }

    /// Dragging the ends is where an off-by-one shows up as a row that vanishes
    /// or reappears in the wrong place.
    func testTheEndsSurviveADrag() {
        XCTAssertEqual(
            AgentOrdering.moving("claude", onto: "cursor", in: roster),
            ["codex", "droid", "cursor", "claude"])
        XCTAssertEqual(
            AgentOrdering.moving("cursor", onto: "claude", in: roster),
            ["cursor", "claude", "codex", "droid"])
    }

    // MARK: Move Up / Move Down

    func testMovingUpTradesPlacesWithTheRowAbove() {
        XCTAssertEqual(
            AgentOrdering.moving("droid", by: -1, in: roster),
            ["claude", "droid", "codex", "cursor"])
    }

    func testMovingDownTradesPlacesWithTheRowBelow() {
        XCTAssertEqual(
            AgentOrdering.moving("codex", by: 1, in: roster),
            ["claude", "droid", "codex", "cursor"])
    }

    /// The menu items are disabled at the ends, but a disabled control is a
    /// presentation decision and this is the layer that has to hold anyway.
    func testTheEndsRefuseToMoveOffTheList() {
        XCTAssertNil(AgentOrdering.moving("claude", by: -1, in: roster))
        XCTAssertNil(AgentOrdering.moving("cursor", by: 1, in: roster))
    }

    /// Repeating Move Up walks a row to the top one step at a time, which is what
    /// makes the menu a usable substitute for dragging rather than a single nudge.
    func testRepeatedMovesWalkARowToTheTop() {
        var ids = roster
        while ids.first != "cursor" {
            guard let moved = AgentOrdering.moving("cursor", by: -1, in: ids) else {
                return XCTFail("stopped walking at \(ids)")
            }
            ids = moved
        }
        XCTAssertEqual(ids, ["cursor", "claude", "codex", "droid"])
    }

    func testAnUnknownRowDoesNotMove() {
        XCTAssertNil(AgentOrdering.moving("ghost", by: 1, in: roster))
    }

    /// Every operation is a permutation: reordering must never lose or duplicate
    /// an agent, which is the failure that would silently drop one from the
    /// New Chat menu.
    func testEveryOperationIsAPermutation() {
        var results: [[String]] = []
        for a in roster {
            for b in roster { AgentOrdering.moving(a, onto: b, in: roster).map { results.append($0) } }
            for offset in [-1, 1] { AgentOrdering.moving(a, by: offset, in: roster).map { results.append($0) } }
        }
        XCTAssertFalse(results.isEmpty)
        for result in results {
            XCTAssertEqual(result.sorted(), roster.sorted(), "not a permutation: \(result)")
        }
    }
}
