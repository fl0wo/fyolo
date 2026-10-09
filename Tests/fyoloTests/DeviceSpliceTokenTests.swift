import XCTest
@testable import fyolo

/// The splice's handshake check is the whole gate in front of a raw daemon
/// socket, so it is tested where a socket is not needed: what it accepts, and
/// what a near miss does.
final class DeviceSpliceTokenTests: XCTestCase {
    func testAcceptsTheTokenBehindTheDaemonPrefix() {
        XCTAssertTrue(DeviceSpliceServer.carries(token: "s3cret", in: "fyolod.s3cret"))
    }

    func testRefusesAnotherToken() {
        XCTAssertFalse(DeviceSpliceServer.carries(token: "s3cret", in: "fyolod.s3crea"))
    }

    /// A prefix of the real token is the shape a length-agnostic comparison
    /// would let through byte by byte.
    func testRefusesAPrefixOfTheToken() {
        XCTAssertFalse(DeviceSpliceServer.carries(token: "s3cret", in: "fyolod.s3cre"))
    }

    /// The subprotocol is how the daemon spells it; a bare token is what a
    /// client that guessed at the contract would send.
    func testRefusesTheTokenWithoutThePrefix() {
        XCTAssertFalse(DeviceSpliceServer.carries(token: "s3cret", in: "s3cret"))
    }

    func testRefusesAnEmptyOffer() {
        XCTAssertFalse(DeviceSpliceServer.carries(token: "s3cret", in: ""))
        XCTAssertFalse(DeviceSpliceServer.carries(token: "s3cret", in: "fyolod."))
    }

    /// The phone and the daemon derive the port from the channel the same way,
    /// and the tunnel has to front whichever one is being served.
    func testServedPortFollowsTheChannelsDevicePort() {
        XCTAssertEqual(DeviceSpliceServer.defaultPort, AppChannel.devicePort)
        XCTAssertNotEqual(AppChannel.devicePort, AppChannel.companionPort)
    }
}
