import XCTest
@testable import fyolo

/// The rule that decides when a phone's companion link is dead. Both directions
/// cost something real: reaping a live link tears down a session the user is
/// typing into, and sparing a dead one leaves the Mac's own window sized to a
/// phone that left the building.
final class LinkLivenessTests: XCTestCase {
    // Held for the test's lifetime — an `ObjectIdentifier` of a temporary is
    // just a freed address, and the next allocation can reuse it.
    private let firstSocket = NSObject()
    private let secondSocket = NSObject()
    private var phone: ObjectIdentifier { ObjectIdentifier(firstSocket) }
    private var other: ObjectIdentifier { ObjectIdentifier(secondSocket) }

    func testLinkAnsweringInsideTheLimitSurvives() {
        var liveness = LinkLiveness()
        liveness.heard(phone, at: 0)
        // The server pings every 20s, so a healthy link refreshes well inside
        // the limit however long the session runs.
        for beat in stride(from: 20.0, through: 200.0, by: 20.0) {
            XCTAssertTrue(liveness.silentLinks(at: beat).isEmpty)
            liveness.heard(phone, at: beat)
        }
    }

    func testSilentLinkIsReapedOnceTheLimitPasses() {
        var liveness = LinkLiveness()
        liveness.heard(phone, at: 0)
        liveness.heard(other, at: 0)
        liveness.heard(other, at: 45)

        XCTAssertTrue(liveness.silentLinks(at: 50).isEmpty, "the limit is exclusive")
        let reaped = liveness.silentLinks(at: 51)
        XCTAssertEqual(reaped.map(\.id), [phone], "only the link that stopped answering")
        XCTAssertEqual(reaped.first?.silence, 51)
    }

    /// The failure this guards against is a mass reap: one blocked runloop would
    /// otherwise look like every phone going silent at the same instant, and
    /// every session on the Mac would lose its bridge together.
    func testAStalledRunloopForgivesTheGapInsteadOfReapingEveryone() {
        var liveness = LinkLiveness()
        liveness.heard(phone, at: 0)
        liveness.heard(other, at: 0)
        XCTAssertTrue(liveness.silentLinks(at: 1).isEmpty)

        // Nothing swept for two minutes: nobody was reading pongs during the
        // gap, so the silence is the Mac's, not the phones'.
        XCTAssertTrue(liveness.silentLinks(at: 121).isEmpty)

        // Back on the tick. One phone answers, the other never does — the
        // stall bought it a fresh limit, not immunity.
        var reaped: [(second: TimeInterval, id: ObjectIdentifier)] = []
        for second in stride(from: 122.0, through: 200.0, by: 1.0) {
            if second == 150 { liveness.heard(other, at: second) }
            reaped += liveness.silentLinks(at: second).map { (second, $0.id) }
        }
        XCTAssertEqual(Set(reaped.map(\.id)), [phone], "the link that stayed silent past the stall is gone")
        XCTAssertEqual(reaped.first?.second, 172, "the stall bought it a fresh limit, not immunity")
    }

    /// `stallGrace` is measured sweep-to-sweep, so sweeping slower than it
    /// makes every round look like a stalled runloop and nothing is ever
    /// reaped. This is the trap in moving the sweep under the 20s ping cadence.
    func testSweepingSlowerThanTheGraceNeverReaps() {
        var liveness = LinkLiveness()
        liveness.heard(phone, at: 0)
        for sweep in stride(from: 20.0, through: 300.0, by: 20.0) {
            XCTAssertTrue(liveness.silentLinks(at: sweep).isEmpty)
        }
    }

    func testForgivenessNeedsAPriorSweepToMeasureAgainst() {
        var liveness = LinkLiveness()
        liveness.heard(phone, at: 0)
        // First sweep of the process's life, long after this socket was
        // accepted: there is no gap to blame, so the silence stands.
        XCTAssertEqual(liveness.silentLinks(at: 100).map(\.id), [phone])
    }

    func testDroppedLinkStopsBeingSwept() {
        var liveness = LinkLiveness()
        liveness.heard(phone, at: 0)
        liveness.forget(phone)
        XCTAssertTrue(liveness.silentLinks(at: 40).isEmpty)

        liveness.heard(phone, at: 41)
        liveness.forgetAll()
        XCTAssertTrue(liveness.silentLinks(at: 42).isEmpty)
    }
}
