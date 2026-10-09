import FyoloShared
import XCTest
@testable import fyolo

/// What a resize's keyframe is allowed to do to the screen.
///
/// The daemon opens its snapshot barrier before it emits `E resized`, and defers
/// events behind an open barrier, so `S` always reaches a client ahead of the
/// message that tells it what size to become. Every rule below follows from
/// that: a keyframe that arrives early must wait, everything behind it must wait
/// with it and in order, and the wait must end — on the grid, on a flood, or on
/// a deadline. Only the first of those three endings paints it: a keyframe drawn
/// for a grid the surface is not laid out at scrambles every row it touches, so
/// the other two drop it and ask for a resync. A wrong answer here shows up as a
/// terminal that paints twice per resize, one that goes quiet, or — the report
/// this was written from — one that scrambles for a round trip on every drag.
final class TerminalKeyframeHoldTests: XCTestCase {
    private let old = TerminalGrid(rows: 21, cols: 45)
    private let new = TerminalGrid(rows: 21, cols: 60)
    private let limit = 1 << 20

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    private func joined(_ chunks: [Data]) -> String {
        String(decoding: chunks.reduce(into: Data(), +=), as: UTF8.self)
    }

    /// The common case: nothing was resized, so nothing waits.
    func testAKeyframeAtTheSurfaceGridPaintsStraightThrough() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        let paint = hold.receive(keyframe: bytes("repaint"), at: old)
        XCTAssertEqual(joined(paint), "repaint")
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(joined(hold.receive(output: bytes("live"), limit: limit).emit), "live")
    }

    /// The resize case: the keyframe describes the size the pane is about to
    /// become, and painting it now would draw it through the old grid.
    func testAKeyframeAheadOfTheSurfacePaintsOnlyWhenTheSurfaceArrives() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertTrue(hold.isHolding)

        // A layout pass that lands somewhere else is not the one being waited on.
        let elsewhere = hold.surfaceReached(TerminalGrid(rows: 21, cols: 50))
        XCTAssertTrue(elsewhere.paint.isEmpty)
        XCTAssertFalse(elsewhere.painted)

        let arrived = hold.surfaceReached(new)
        XCTAssertEqual(joined(arrived.paint), "repaint")
        XCTAssertTrue(arrived.painted)
        XCTAssertFalse(hold.isHolding)
    }

    /// `painted` is what stands down the resync. Reporting it for a grid nobody
    /// was waiting on would suppress the repair the degraded path depends on.
    func testOnlyTheGridThatWasWaitedOnReportsPainted() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertFalse(hold.surfaceReached(new).painted)
        XCTAssertEqual(hold.surfaceGrid, new)
    }

    /// Live output behind a held keyframe is a continuation of the screen that
    /// keyframe describes. Letting it overtake would paint it onto the old one.
    func testOutputQueuesBehindAHeldKeyframeAndFollowsItInOrder() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("one"), limit: limit).emit.isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("two"), limit: limit).emit.isEmpty)

        XCTAssertEqual(joined(hold.surfaceReached(new).paint), "repaintonetwo")
        XCTAssertEqual(joined(hold.receive(output: bytes("three"), limit: limit).emit), "three")
    }

    /// A second keyframe describes a screen the daemon captured past the writes
    /// queued behind the first, so replaying them would double them.
    func testANewerKeyframeSupersedesWhatWasQueuedBehindTheOlderOne() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("first"), at: new).isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("stale"), limit: limit).emit.isEmpty)

        let taller = TerminalGrid(rows: 30, cols: 60)
        XCTAssertTrue(hold.receive(keyframe: bytes("second"), at: taller).isEmpty)
        XCTAssertEqual(joined(hold.surfaceReached(taller).paint), "second")
    }

    /// A program that floods through a resize must not grow this buffer without
    /// bound. Past the cap the wait is given up on — the live bytes go out, the
    /// keyframe does not, and `gaveUp` is what tells the link to ask for the
    /// repaint.
    func testAFloodBehindAHeldKeyframeEndsTheWaitWithoutPaintingIt() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("ab"), limit: 4).emit.isEmpty)

        let flooded = hold.receive(output: bytes("cde"), limit: 4)
        XCTAssertEqual(joined(flooded.emit), "abcde")
        XCTAssertTrue(flooded.gaveUp)
        XCTAssertFalse(hold.isHolding)
    }

    /// The deadline drops the keyframe rather than painting it: a screen drawn
    /// for one grid, written into a surface laid out at another, wraps every row
    /// somewhere the daemon never put it. Leaving the last correct screen up and
    /// asking for a resync is the cheaper wrong answer, and the only one that
    /// never shows the user a scrambled frame.
    ///
    /// What queued behind it goes too. This used to flush, on the reasoning that
    /// live bytes are the child's and this is not the layer that discards them —
    /// but they are the child's *increments against the screen that was just
    /// dropped*, cursor-addressed and relative to a base the surface never
    /// received. Painting them onto the previous screen draws the new width's
    /// rows over rows still standing at the old one, which is the two-widths-at-
    /// once artifact a window resize left behind. They are superseded whole by
    /// the resync the caller arms on the way out of here.
    func testGivingUpDropsTheKeyframeAndTheIncrementsThatNeededIt() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("live"), limit: limit).emit.isEmpty)

        hold.discard()
        XCTAssertFalse(hold.isHolding)
        hold.discard()
        XCTAssertTrue(hold.release().isEmpty, "an abandoned keyframe must not paint later")
    }

    /// Output that arrives once the hold is over is ordinary live output again,
    /// not part of the dropped keyframe's tail — the drop must not turn into a
    /// mute.
    func testOutputAfterAGiveUpFlowsStraightThrough() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("dropped"), limit: limit).emit.isEmpty)
        hold.discard()

        let after = hold.receive(output: bytes("after"), limit: limit)
        XCTAssertEqual(joined(after.emit), "after")
    }

    /// Teardown is the one ending that still paints: a surface that is going
    /// away has no resync coming, so an imperfectly wrapped final frame beats a
    /// blank one. A hold that already ended must not paint it a second time.
    func testTeardownPaintsOnceAndOnlyOnce() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertEqual(joined(hold.release()), "repaint")
        XCTAssertTrue(hold.release().isEmpty)
    }

    /// A resync's answer is not held. The resync is only ever asked for after a
    /// hold already failed to deliver a keyframe, so holding its answer would
    /// wait on the grid the surface did not reach the first time, give up the
    /// same way, and ask again — a loop that leaves the pane on its pre-resize
    /// screen for as long as it runs.
    func testAKeyframeAnsweringARepaintWeAskedForIsNotHeld() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("held"), at: new).isEmpty)
        hold.discard()

        hold.paintNextKeyframe()
        XCTAssertEqual(joined(hold.receive(keyframe: bytes("resync"), at: new)), "resync")
        XCTAssertFalse(hold.isHolding)

        // One keyframe only: the next resize waits its turn like any other.
        XCTAssertTrue(hold.receive(keyframe: bytes("later"), at: new).isEmpty)
        XCTAssertTrue(hold.isHolding)
    }

    /// The epoch is how a deadline armed for one keyframe knows it is stale. It
    /// has to move on every open and every close, or a late timer paints a
    /// keyframe the surface has already been given.
    func testEveryOpenAndCloseMovesTheEpoch() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        let start = hold.epoch
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        let armed = hold.epoch
        XCTAssertNotEqual(armed, start)
        XCTAssertTrue(hold.surfaceReached(new).painted)
        XCTAssertNotEqual(hold.epoch, armed)
    }
}
