import XCTest

@testable import fyolo

/// How hard the tunnel retries after an unexpected exit. The curve is the whole
/// policy: too flat and a hard failure mints a new public URL every few seconds
/// (which is what happened — eight in twenty-two seconds, each one breaking a
/// paired phone's QR); too steep and a relay that recovers stays down for hours.
@MainActor
final class TunnelRestartBackoffTests: XCTestCase {
    func testTheFirstRetryIsPromptSoAnOrdinaryBlipIsInvisible() {
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: 1), 3)
    }

    func testEachConsecutiveFailureDoublesTheWait() {
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: 2), 6)
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: 3), 12)
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: 4), 24)
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: 5), 48)
    }

    /// The point of the ceiling: a hard failure costs one attempt per five
    /// minutes forever, rather than being abandoned. A tunnel abandoned at a
    /// fixed count stayed down until the user reselected the provider by hand,
    /// even when the relay had come back on its own.
    func testTheWaitIsHeldAtFiveMinutes() {
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: 8), 300)
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: 50), 300)
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: 10_000), 300)
    }

    /// Nothing calls it this way, but a counter that ever read zero or negative
    /// must not produce a negative deadline — `asyncAfter` would fire it
    /// immediately and restore the hot loop this curve exists to prevent.
    func testANonPositiveCountStillYieldsThePromptDelay() {
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: 0), 3)
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: -1), 3)
        // `failures - 1` traps on the most negative Int, so the guard has to
        // come before the subtraction rather than after it.
        XCTAssertEqual(TunnelManager.restartDelay(afterFailures: .min), 3)
    }

    func testTheCurveNeverDecreases() {
        let delays = (1...20).map { TunnelManager.restartDelay(afterFailures: $0) }
        XCTAssertEqual(delays, delays.sorted())
    }
}
