import XCTest
import FyoloShared
@testable import fyolo

/// The one piece of arithmetic both clients declare their viewport with.
///
/// It is worth pinning because nothing else can catch it going wrong: a client
/// that floors differently, or forgets that padding is on both sides, declares a
/// grid its own surface then disagrees with by a column — and the visible result
/// is not an error but a pane that letterboxes against itself, or a session that
/// creeps a column narrower every time it is measured.
final class TerminalViewportGridTests: XCTestCase {
    private let cell = CGSize(width: 8, height: 20)

    private func grid(_ width: CGFloat, _ height: CGFloat,
                      paddingX: CGFloat = 4, paddingY: CGFloat = 2) -> TerminalGrid? {
        TerminalGrid.fitting(
            CGSize(width: width, height: height), cell: cell,
            paddingX: paddingX, paddingY: paddingY)
    }

    /// Padding is subtracted on *both* sides, and the remainder is floored.
    func testWholeCellsAfterPaddingOnBothSides() {
        // 808 − 2×4 = 800 = 100 cells exactly; 404 − 2×2 = 400 = 20 rows.
        XCTAssertEqual(grid(808, 404), TerminalGrid(rows: 20, cols: 100))
    }

    /// A pane one point short of the next cell keeps the smaller grid. Rounding
    /// here would declare room the surface does not have, and the surface would
    /// answer with a grid one column narrower than the session it was given.
    func testShortOfACellDoesNotRoundUp() {
        XCTAssertEqual(grid(815, 404)?.cols, 100)
        XCTAssertEqual(grid(816, 404)?.cols, 101)
        XCTAssertEqual(grid(808, 423)?.rows, 20)
        XCTAssertEqual(grid(808, 424)?.rows, 21)
    }

    /// Anything that cannot hold a whole cell is "no viewport at all", which the
    /// host counts for nobody — deliberately not a stand-in grid, which would
    /// size the session for a window that has not laid out yet.
    func testTooSmallOrUnmeasuredIsNoViewport() {
        XCTAssertNil(grid(0, 0))
        XCTAssertNil(grid(-100, -100))
        XCTAssertNil(grid(8, 404), "narrower than one cell plus its padding")
        XCTAssertNil(grid(808, 20), "shorter than one row plus its padding")
        XCTAssertNil(TerminalGrid.fitting(
            CGSize(width: 800, height: 400), cell: .zero, paddingX: 4, paddingY: 2),
            "no cell size yet")
    }

    /// A NaN anywhere in the layout must not reach `UInt16`, which traps.
    func testNonFiniteIsRefusedRatherThanTrapping() {
        XCTAssertNil(grid(CGFloat.nan, 400))
        XCTAssertNil(grid(800, CGFloat.nan))
        XCTAssertNil(grid(CGFloat.infinity, CGFloat.infinity))
        XCTAssertNil(TerminalGrid.fitting(
            CGSize(width: 800, height: 400), cell: CGSize(width: CGFloat.nan, height: 20),
            paddingX: 4, paddingY: 2))
    }

    /// A window dragged onto a wall of displays still describes a grid a `u16`
    /// can carry, and one the daemon will not try to allocate a screen for.
    func testAbsurdSizesClamp() {
        let huge = grid(10_000_000, 10_000_000)
        XCTAssertEqual(huge?.cols, 10_000)
        XCTAssertEqual(huge?.rows, 10_000)
    }

    /// Zero padding is a legitimate setting, not a special case.
    func testZeroPaddingUsesTheWholeRectangle() {
        XCTAssertEqual(
            grid(800, 400, paddingX: 0, paddingY: 0), TerminalGrid(rows: 20, cols: 100))
    }
}
